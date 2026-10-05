"""Sustained real Cloudflare signaling + local WebRTC media/control soak.

Two virtual peers, not physical Android devices. Media uses a local ICE path;
TURN issuance is checked but relay/NAT and Android MediaCodec are not emulated.
Requires aiortc==1.14.0 and websockets==15.0.1. Never prints credentials/SDP.
Usage: python3 cloudflare/soak-session.py --seconds 600
"""
import argparse
import asyncio
import fractions
import json
import secrets
import struct
import time
import urllib.error
import urllib.request

import numpy as np
import websockets
from av import VideoFrame
from aiortc import RTCConfiguration, RTCPeerConnection, RTCRtpSender, RTCSessionDescription, VideoStreamTrack

PRIMARY = "https://aaris-remote-ice.aaris-remote-wk3548.workers.dev"
FALLBACK = "https://aaris-remote-connect.pages.dev"


def http(origin, path, token=None, payload=None):
    headers = {"Content-Type": "application/json", "User-Agent": "AarisRemote-Session-Soak/1.9.12"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(origin + path, headers=headers,
        data=None if payload is None else json.dumps(payload).encode())
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


async def api(origin, path, token=None, payload=None):
    return await asyncio.to_thread(http, origin, path, token, payload)


class MovingScreen(VideoStreamTrack):
    def __init__(self):
        super().__init__()
        self.started = None
        self.index = 0

    async def recv(self):
        now = time.monotonic()
        if self.started is None:
            self.started = now
        target = self.started + self.index / 24
        await asyncio.sleep(max(0, target - now))
        # Latest pixels; no catch-up queue after scheduler pressure.
        self.index = max(self.index, int((time.monotonic() - self.started) * 24))
        pixels = np.zeros((1200, 540, 3), dtype=np.uint8)
        pixels[:] = [24, 32, 48]
        row = (self.index * 12) % 1000
        pixels[row:row + 120, :, :] = [35, 110, 240]
        for column in range(30, 510, 80):
            pixels[1100:1150, column:column + 50] = [(self.index * 3) % 255, 180, 90]
        frame = VideoFrame.from_ndarray(pixels, format="rgb24")
        frame.pts = self.index * 3750
        frame.time_base = fractions.Fraction(1, 90000)
        self.index += 1
        return frame


class SignalSocket:
    def __init__(self, origin, path, token):
        self.origin, self.path, self.token = origin, path, token
        self.ws = None
        self.after = 0

    async def open(self):
        self.ws = await websockets.connect(
            self.origin.replace("https://", "wss://") + self.path + f"/socket?after={self.after}",
            additional_headers={"Authorization": "Bearer " + self.token},
            open_timeout=20, close_timeout=3, max_size=786432)
        await self.expect(lambda packet: packet.get("kind") == "session")

    async def expect(self, predicate):
        for _ in range(40):
            packet = json.loads(await asyncio.wait_for(self.ws.recv(), 20))
            assert packet.get("session", {}).get("state") != "CLOSED", "Session closed unexpectedly"
            self.after = max(self.after, packet.get("event", {}).get("seq", 0))
            if predicate(packet):
                return packet
        raise AssertionError("Expected signaling event missing")

    async def close(self):
        if self.ws is not None:
            await self.ws.close()
            self.ws = None


async def soak(seconds):
    host_info = None
    sockets = []
    peers = []
    tasks = []
    counts = {"frames": 0, "heartbeats": 0, "motion": 0, "acks": 0, "max_frame_gap_ms": 0.0}
    last_frame = None
    errors = []
    try:
        for origin in (PRIMARY, FALLBACK):
            assert (await api(origin, "/healthz"))["ok"]
        host_info = await api(PRIMARY, "/v1/sessions", payload={})
        path = "/v1/sessions/" + host_info["sessionId"]
        controller_token = secrets.token_urlsafe(32)
        controller = await api(FALLBACK, "/v1/sessions/redeem", payload={
            "code": host_info["code"], "controllerToken": controller_token})
        assert controller["sessionId"] == host_info["sessionId"]
        await api(PRIMARY, path + "/state", host_info["hostToken"], {"target": "HOST_APPROVED"})
        ice = await api(FALLBACK, path + "/ice", controller_token, {})
        assert any(str(url).startswith(("turn:", "turns:")) for item in ice["iceServers"]
            for url in ([item["urls"]] if isinstance(item["urls"], str) else item["urls"]))
        await api(PRIMARY, path + "/state", host_info["hostToken"], {"target": "SCREEN_READY"})

        host_pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        controller_pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        peers = [host_pc, controller_pc]
        screen = MovingScreen()
        host_pc.addTrack(screen)
        controller_pc.addTransceiver("video", direction="recvonly")
        lanes = {}
        open_event = asyncio.Event()
        host_reliable = host_pc.createDataChannel("control-v1", ordered=True)
        host_motion = host_pc.createDataChannel("control-live-v1", ordered=False, maxRetransmits=0)

        @host_reliable.on("message")
        def on_heartbeat(message):
            counts["heartbeats"] += 1
            host_reliable.send(message)

        @host_motion.on("message")
        def on_motion(message):
            counts["motion"] += 1

        @controller_pc.on("datachannel")
        def on_channel(channel):
            lanes[channel.label] = channel
            if channel.label == "control-v1":
                @channel.on("message")
                def on_ack(message):
                    counts["acks"] += 1
            if len(lanes) == 2:
                open_event.set()

        async def consume(track):
            nonlocal last_frame
            try:
                while True:
                    await asyncio.wait_for(track.recv(), 15)
                    now = time.monotonic()
                    if last_frame is not None:
                        counts["max_frame_gap_ms"] = max(counts["max_frame_gap_ms"], (now - last_frame) * 1000)
                    last_frame = now
                    counts["frames"] += 1
            except asyncio.CancelledError:
                raise
            except Exception as error:
                errors.append(type(error).__name__)

        @controller_pc.on("track")
        def on_track(track):
            tasks.append(asyncio.create_task(consume(track)))

        host_socket = SignalSocket(PRIMARY, path, host_info["hostToken"])
        controller_socket = SignalSocket(FALLBACK, path, controller_token)
        sockets = [host_socket, controller_socket]
        await host_socket.open()
        await controller_socket.open()

        async def negotiate(codec, generation):
            transceiver = host_pc.getTransceivers()[0]
            codecs = [item for item in RTCRtpSender.getCapabilities("video").codecs
                if item.mimeType.lower() == "video/" + codec.lower()]
            assert codecs, "Requested codec unavailable"
            transceiver.setCodecPreferences(codecs)
            await host_pc.setLocalDescription(await host_pc.createOffer())
            event = await api(PRIMARY, path + "/events", host_info["hostToken"], {
                "kind": "description", "payload": {"type": "offer", "sdp": host_pc.localDescription.sdp,
                    "negotiationId": f"soak:{generation}"}})
            received = await controller_socket.expect(lambda packet: packet.get("event", {}).get("seq") == event["event"]["seq"])
            await controller_pc.setRemoteDescription(RTCSessionDescription(received["event"]["payload"]["sdp"], "offer"))
            await controller_pc.setLocalDescription(await controller_pc.createAnswer())
            event = await api(FALLBACK, path + "/events", controller_token, {
                "kind": "description", "payload": {"type": "answer", "sdp": controller_pc.localDescription.sdp,
                    "replyToNegotiationId": f"soak:{generation}"}})
            received = await host_socket.expect(lambda packet: packet.get("event", {}).get("seq") == event["event"]["seq"])
            await host_pc.setRemoteDescription(RTCSessionDescription(received["event"]["payload"]["sdp"], "answer"))

        await negotiate("VP8", 1)
        await asyncio.wait_for(open_event.wait(), 30)
        async def wait_for_channels():
            while any(channel.readyState != "open" for channel in lanes.values()):
                await asyncio.sleep(0.05)
        await asyncio.wait_for(wait_for_channels(), 15)
        await api(PRIMARY, path + "/state", host_info["hostToken"], {"target": "LIVE"})
        started = time.monotonic()

        async def send_heartbeats():
            sequence = 0
            while True:
                sequence += 1
                lanes["control-v1"].send(struct.pack("!Q", sequence))
                await asyncio.sleep(5)

        async def send_motion():
            sequence = 0
            while True:
                sequence += 1
                lanes["control-live-v1"].send(struct.pack("!Q", sequence))
                await asyncio.sleep(1 / 30)

        tasks.extend([asyncio.create_task(send_heartbeats()), asyncio.create_task(send_motion())])
        print("START: two virtual peers, production cross-route signaling, local UDP/RTP video, SCTP heartbeat + motion; TURN issuance verified", flush=True)
        previous_frames = 0
        dropped = False
        reconnected = False
        renegotiated = False
        while time.monotonic() - started < seconds:
            await asyncio.sleep(min(15, seconds - (time.monotonic() - started)))
            elapsed = time.monotonic() - started
            for origin, token in ((PRIMARY, host_info["hostToken"]), (FALLBACK, controller_token)):
                state = (await api(origin, path, token))["session"]
                assert state["state"] == "LIVE" and state["deadlineAtMs"] is None, "Live session expired"
            assert not errors, "Media consumer failed"
            assert counts["frames"] > previous_frames, "Decoded video stopped"
            assert all(peer.connectionState == "connected" for peer in peers), "WebRTC peer disconnected"
            assert all(not task.done() for task in tasks), "Media/control task stopped"
            previous_frames = counts["frames"]
            if elapsed >= 60 and not dropped:
                await controller_socket.close()
                dropped = True
                print("INJECT: controller signaling socket down; media/control remain active", flush=True)
            if elapsed >= 90 and not reconnected:
                controller_socket.origin = PRIMARY
                await controller_socket.open()
                reconnected = True
                print("PASS: signaling route changed and reconnected without ending session", flush=True)
            if elapsed >= 120 and not renegotiated:
                await negotiate("H264", 2)
                renegotiated = True
                print("PASS: VP8 -> H264 renegotiated within the same media/control session", flush=True)
            print(f"CHECK: {elapsed:.0f}s LIVE; decoded={counts['frames']} heartbeat={counts['heartbeats']} ack={counts['acks']} motion={counts['motion']}", flush=True)
        elapsed = time.monotonic() - started
        assert reconnected and renegotiated and counts["acks"] >= int(seconds / 5) - 3
        assert counts["motion"] >= seconds * 20, "Motion channel throughput fell below 20 messages/second"
        assert counts["frames"] / elapsed >= 18, "Synthetic video averaged below 18 decoded frames/second"
        assert counts["max_frame_gap_ms"] < 10_000, "Synthetic video paused for ten seconds"
        print("PASS: sustained session " + json.dumps({"seconds": round(elapsed, 1),
            "average_decoded_fps": round(counts["frames"] / elapsed, 2),
            "media_path": "local ICE between virtual peers", "android_devices": 0, **counts}), flush=True)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.gather(*(peer.close() for peer in peers), return_exceptions=True)
        await asyncio.gather(*(item.close() for item in sockets), return_exceptions=True)
        if host_info:
            closed = await api(FALLBACK, "/v1/sessions/" + host_info["sessionId"] + "/close", host_info["hostToken"], {})
            assert closed["session"]["state"] == "CLOSED"
            print("PASS: synthetic session closed", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=600)
    args = parser.parse_args()
    if not 300 <= args.seconds <= 1800:
        parser.error("--seconds must be between 300 and 1800")
    try:
        asyncio.run(soak(args.seconds))
    except Exception as error:
        print("FAIL:", type(error).__name__, flush=True)
        if isinstance(error, AssertionError):
            print(str(error), flush=True)
        raise SystemExit(1)
