"""Verify cross-route pairing and signaling using synthetic sessions only.

Usage: python3 cloudflare/smoke-connect.py [primary_origin] [fallback_origin]
Requires websockets. Session credentials and pairing codes are never printed.
Every created session is closed in finally, including when a check fails.
"""
import asyncio
import json
import secrets
import sys
import urllib.error
import urllib.request

import websockets

PRIMARY = sys.argv[1] if len(sys.argv) > 1 else "https://aaris-remote-ice.aaris-remote-wk3548.workers.dev"
FALLBACK = sys.argv[2] if len(sys.argv) > 2 else "https://aaris-remote-connect.pages.dev"


def http(origin, path, payload=None, token=None):
    headers = {"Content-Type": "application/json", "Accept": "application/json",
               "User-Agent": "AarisRemote-Connect-Smoke/1.9.11"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(origin + path,
        data=None if payload is None else json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


async def checked(origin, path, payload=None, token=None, expected=200):
    status, result = await asyncio.to_thread(http, origin, path, payload, token)
    assert status == expected, f"Unexpected HTTP status on {path.rsplit('/', 1)[-1]}: {status}"
    return result


def has_turn(result):
    for server in result.get("iceServers", []):
        urls = server.get("urls", [])
        if isinstance(urls, str):
            urls = [urls]
        if any(url.startswith(("turn:", "turns:")) for url in urls):
            return True
    return False


async def recv_match(socket, predicate):
    for _ in range(30):
        packet = json.loads(await asyncio.wait_for(socket.recv(), 15))
        if predicate(packet):
            return packet
    raise AssertionError("Expected signaling packet was not delivered")


def socket(origin, path, token, after=0):
    return websockets.connect(origin.replace("https://", "wss://") + path + f"/socket?after={after}",
        additional_headers={"Authorization": f"Bearer {token}"},
        user_agent_header="AarisRemote-Connect-Smoke/1.9.11", open_timeout=20, close_timeout=3)


async def check_pair(host_origin, controller_origin, label):
    host = None
    try:
        host = await checked(host_origin, "/v1/sessions", {}, expected=201)
        path = "/v1/sessions/" + host["sessionId"]
        token = secrets.token_urlsafe(32)
        redeem = {"code": host["code"], "controllerToken": token}
        controller = await checked(controller_origin, "/v1/sessions/redeem", redeem)
        assert controller["sessionId"] == host["sessionId"], "Routes used different session stores"
        assert (await checked(host_origin, path, token=host["hostToken"]))["session"]["state"] == "PAIR_PENDING"
        await checked(controller_origin, path + "/ice", {}, token, expected=403)
        await checked(controller_origin, path + "/state", {"target": "HOST_APPROVED"}, token, expected=403)
        await checked(host_origin, path + "/state", {"target": "HOST_APPROVED"}, host["hostToken"])
        # Reproduce a lost redeem response, followed by a network-route change.
        retry = await checked(host_origin, "/v1/sessions/redeem", redeem)
        assert retry["controllerUid"] == controller["controllerUid"], "Retry changed controller ownership"
        await checked(controller_origin, "/v1/sessions/redeem",
            {"code": host["code"], "controllerToken": secrets.token_urlsafe(32)}, expected=409)
        assert has_turn(await checked(controller_origin, path + "/ice", {}, token)), "Prewarm TURN missing"

        async with socket(controller_origin, path, token) as controller_ws:
            initial = await recv_match(controller_ws, lambda p: p.get("kind") == "session")
            assert initial["session"]["state"] == "HOST_APPROVED", "Controller socket prewarm state"
            await checked(host_origin, path + "/state", {"target": "SCREEN_READY"}, host["hostToken"])
            await recv_match(controller_ws, lambda p: p.get("session", {}).get("state") == "SCREEN_READY")
            offer = await checked(host_origin, path + "/events", {
                "kind": "description", "payload": {"type": "offer", "sdp": "v=0", "negotiationId": "route-smoke:1"}
            }, host["hostToken"], expected=201)
            received = await recv_match(controller_ws, lambda p: p.get("event", {}).get("kind") == "description")
            assert received["event"]["seq"] == offer["event"]["seq"], "Cross-route offer delivery"
            async with socket(host_origin, path, host["hostToken"]) as host_ws:
                await recv_match(host_ws, lambda p: p.get("kind") == "session")
                answer = await checked(controller_origin, path + "/events", {
                    "kind": "description", "payload": {"type": "answer", "sdp": "v=0", "replyToNegotiationId": "route-smoke:1"}
                }, token, expected=201)
                await recv_match(host_ws, lambda p: p.get("event", {}).get("seq") == answer["event"]["seq"])
                candidate = await checked(host_origin, path + "/events", {
                    "kind": "candidate", "payload": {"mid": "0", "mLine": 0,
                        "sdp": "candidate:route-smoke 1 udp 1 192.0.2.1 9 typ host", "negotiationId": "route-smoke:1"}
                }, host["hostToken"], expected=201)
                await recv_match(controller_ws, lambda p: p.get("event", {}).get("seq") == candidate["event"]["seq"])

        # Reconnect on the other public origin without losing the replay cursor.
        async with socket(host_origin, path, token, after=offer["event"]["seq"]) as replay_ws:
            await recv_match(replay_ws, lambda p: p.get("kind") == "session")
            replay = await recv_match(replay_ws, lambda p: p.get("event", {}).get("kind") == "description")
            assert replay["event"]["seq"] == answer["event"]["seq"], "Cross-route replay skipped or duplicated an event"

        assert has_turn(await checked(host_origin, path + "/ice", {}, host["hostToken"])), "Host TURN missing"
        await checked(host_origin, path + "/state", {"target": "LIVE"}, host["hostToken"])
        assert (await checked(controller_origin, path, token=token))["session"]["state"] == "LIVE"
        print(f"PASS: {label}: create, redeem, retry ownership, consent gates, approval, TURN, WebSocket offer/answer/candidate, route-change replay, LIVE", flush=True)
    finally:
        if host:
            path = "/v1/sessions/" + host["sessionId"]
            # Close through the alternate origin, proving shared cleanup too.
            closed = await checked(controller_origin, path + "/close", {}, host["hostToken"])
            assert closed["session"]["state"] == "CLOSED", "Synthetic session cleanup failed"
            print(f"PASS: {label}: synthetic session closed", flush=True)


async def main():
    for origin in (PRIMARY, FALLBACK):
        assert (await checked(origin, "/healthz"))["service"] == "aaris-remote-ice"
    await check_pair(PRIMARY, FALLBACK, "primary host / fallback controller")
    await check_pair(FALLBACK, PRIMARY, "fallback host / primary controller")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as error:
        print("FAIL:", type(error).__name__, flush=True)
        if isinstance(error, AssertionError):
            print(str(error), flush=True)
        sys.exit(1)
