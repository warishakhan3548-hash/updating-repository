# Architecture

## Planes

1. **Session plane** — strict state machine and fail-closed session guard.
2. **Pairing plane** — Firebase anonymous identity + callable functions for short-lived single-use codes.
3. **Signaling plane** — Realtime Database SDP/ICE exchange scoped to the two session participants.
4. **Media plane** — MediaProjection -> WebRTC video track -> controller renderer.
5. **Control plane** — compact WebRTC data messages -> generation-aware coordinate mapper -> AccessibilityService gestures.
6. **Safety plane** — no valid LIVE lease means no gesture execution; STOP/network loss/projector stop revokes the lease.
7. **Transport-truth plane** — a controller is connected only when the WebRTC peer and ordered control DataChannel are both ready.
8. **Deadline plane** — code discovery, host approval, and screen/transport setup have independent server deadlines.

## Session states

IDLE -> SETUP_REQUIRED -> READY -> CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_CONSENT -> CONNECTING -> LIVE -> CLOSED

Every transition is monotonic for a session. A closed session is never revived.

## Latency policy

Control responsiveness wins over visual quality. Video bitrate/resolution may degrade under congestion; command traffic is isolated from the video track. Stale display generations and stale gesture packets are discarded.

## Coordinate policy

Controller touch points are mapped through the actual rendered remote-video rectangle, normalized to [0,1], then transformed into the latest remote display generation. Touches outside the video viewport are ignored.


## Pairing deadlines

`CODE_ACTIVE` uses a five-minute one-time-code lifetime. A successful redeem moves the session to `PAIR_PENDING` and starts a fresh three-minute host-approval deadline. Host approval starts a separate three-minute screen/transport setup deadline. This prevents a code entered near the end of its discovery lifetime from prematurely expiring an otherwise valid consent flow.

## Transport readiness

WebRTC peer connectivity alone is not treated as usable remote control. The controller becomes connected only when both the peer connection and the ordered `control-v1` DataChannel are ready. The host's initial watchdog remains armed until both conditions are true, so a half-open transport cannot remain stuck indefinitely.

## Local-control liveness

A LIVE control lease is valid only while the host AccessibilityService remains connected. The host watchdog checks this alongside lease expiry; if Android disables or removes the service, the session closes instead of silently degrading into a misleading view-only connection.

## Interaction-first media policy

The host applies an RTP sender policy that prefers maintaining frame cadence under congestion and caps the video send envelope. WebRTC remains free to reduce resolution/bitrate below that ceiling, prioritizing responsive touch feedback over preserving every pixel at a fixed quality.

## Production network boundary

The client first requests session-bound ICE configuration from the `asia-south1` `getIceConfig` callable. The function always supplies STUN and, when relay configuration is deployed, mints short-lived coturn REST credentials only for the authenticated host/controller of an active `SCREEN_READY` or `LIVE` session.

Carrier-grade or symmetric NAT still requires real TURN infrastructure for high connection coverage. Configure reachable UDP TURN plus TCP/TLS fallback through `TURN_URLS` and keep `TURN_SHARED_SECRET` only in the Firebase Functions secret store; never hard-code relay credentials in the APK. If relay configuration is unavailable, the client deliberately falls back to STUN-only best-effort connectivity.
