"""Live transport test with synthetic phones only; never prints capability URLs/tokens.

Usage: python smoke-mcp.py [https://your-worker.workers.dev]
Requires websockets. Created links are revoked in finally.
"""
import asyncio
import json
import secrets
import sys
import urllib.error
import urllib.request
import websockets

BASE = sys.argv[1] if len(sys.argv) > 1 else "https://aaris-phone-mcp.aaris-remote-wk3548.workers.dev"
# A tiny fixture is sufficient to prove that MCP image blocks survive the transport.
IMAGE = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q=='

def http(path, payload=None, token=None):
    headers = {"User-Agent": "AarisRemote-MCP-Smoke/1.0", "Content-Type": "application/json", "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(BASE + path, data=None if payload is None else json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=28) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")

def call(phone, tool, args=None):
    return http(f"/mcp/{phone['id']}/{phone['client']}", {"jsonrpc": "2.0", "id": secrets.token_hex(6), "method": "tools/call", "params": {"name": tool, "arguments": args or {}}})

def metadata(response):
    status, packet = response
    assert status == 200, "MCP HTTP status"
    assert "result" in packet, "MCP result"
    return json.loads(packet["result"]["content"][0]["text"])

async def main():
    phones = [{"id": secrets.token_hex(32), "device": secrets.token_hex(32), "client": secrets.token_hex(32)} for _ in range(2)]
    try:
        for phone in phones:
            status, body = await asyncio.to_thread(http, f"/v1/connectors/{phone['id']}/register", {"clientToken": phone['client']}, phone['device'])
            assert status == 200 and body.get("ok"), "Provision device"
        p = phones[0]
        status, initialized = await asyncio.to_thread(http, f"/mcp/{p['id']}/{p['client']}", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "aaris-smoke", "version": "1"}}})
        assert status == 200 and initialized["result"]["protocolVersion"] == "2025-11-25", "Initialize"
        assert metadata(await asyncio.to_thread(call, p, "phone_status"))["online"] is False, "Initially offline"
        uri = BASE.replace("https://", "wss://") + f"/v1/connectors/{p['id']}/socket"
        async with websockets.connect(uri, additional_headers={"Authorization": f"Bearer {p['device']}"}, user_agent_header="AarisRemote-MCP-Smoke/1.0", open_timeout=12) as ws:
            await ws.send(json.dumps({"type": "ready", "runId": "simulated-phone-1"}))
            assert json.loads(await asyncio.wait_for(ws.recv(), 10))["type"] == "ack", "Ready ACK"
            assert metadata(await asyncio.to_thread(call, p, "phone_status"))["online"] is True, "Online"
            assert metadata(await asyncio.to_thread(call, phones[1], "phone_status"))["online"] is False, "Device isolation"
            observation = {"screenVersion": 1, "observationId": "synthetic-observation-001", "image": {"mimeType": "image/jpeg", "data": IMAGE, "width": 1, "height": 1}}
            future = asyncio.create_task(asyncio.to_thread(call, p, "phone_observe"))
            request = json.loads(await asyncio.wait_for(ws.recv(), 10))
            assert request["tool"] == "phone_observe" and request["runId"] == "simulated-phone-1", "Route observation"
            await ws.send(json.dumps({"type": "result", "requestId": request["requestId"], "result": observation}))
            observed = await future
            assert observed[1]["result"]["content"][1]["type"] == "image", "MCP image"
            action = {"actionId": "synthetic-step-0001", "observationId": observation["observationId"], "screenVersion": 1, "action": "tap", "x": 0.5, "y": 0.5}
            future = asyncio.create_task(asyncio.to_thread(call, p, "phone_action", action))
            request = json.loads(await asyncio.wait_for(ws.recv(), 10))
            assert request["arguments"] == action, "Exact action forwarding"
            busy = metadata(await asyncio.to_thread(call, p, "phone_action", {**action, "actionId": "synthetic-step-0002"}))
            assert busy["error"] == "BUSY", "Concurrent action rejection"
            await ws.send(json.dumps({"type": "result", "requestId": request["requestId"], "result": {**observation, "applied": True, "screenVersion": 2}}))
            assert metadata(await future)["applied"] is True, "Action result"
            replay = metadata(await asyncio.to_thread(call, p, "phone_action", action))
            assert replay["replayed"] is True and replay["applied"] is True, "Durable retry"
            # Hibernation destroys in-memory fields, while the open socket and ledger survive.
            await asyncio.sleep(12)
            await ws.send(json.dumps({"type": "heartbeat"}))
            assert json.loads(await asyncio.wait_for(ws.recv(), 10))["type"] == "ack", "Wake from idle"
            replay = metadata(await asyncio.to_thread(call, p, "phone_action", action))
            assert replay["replayed"] is True, "Replay after idle"
            uncertain = {**action, "actionId": "synthetic-step-unknown"}
            future = asyncio.create_task(asyncio.to_thread(call, p, "phone_action", uncertain))
            request = json.loads(await asyncio.wait_for(ws.recv(), 10))
            await ws.close()
            assert metadata(await future)["applied"] is None, "Disconnect outcome must be unknown"
            assert metadata(await asyncio.to_thread(call, p, "phone_action", uncertain))["replayed"] is True, "Never replay ambiguous action"
        print("PASS: live provision, initialize, device isolation, image roundtrip, one action + image, busy, durable retry, idle wake, disconnect outcome")
    finally:
        for phone in phones:
            status, _ = await asyncio.to_thread(http, f"/v1/connectors/{phone['id']}/revoke", {"clientToken": phone['client']}, phone['device'])
            if status == 200:
                status, _ = await asyncio.to_thread(call, phone, "phone_status")
                assert status == 401, "Revoked link still accessible"
        print("PASS: synthetic links revoked")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as error:
        # HTTP exceptions may embed capability URLs. Do not print their raw text.
        print("FAIL:", type(error).__name__)
        if isinstance(error, AssertionError):
            print(str(error))
        sys.exit(1)
