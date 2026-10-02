# Aaris Remote architecture

## Core rule

There is one authoritative remote session on Cloudflare and one deterministic local state machine on each Android peer. The screen and control payloads do not pass through the Worker.

## Planes

1. **Local state plane** — Android `SessionCoordinator` owns local UI/runtime state.
2. **Pairing plane** — `PairingDirectory` Durable Object maps a hashed one-time code to a random session ID and consumes it exactly once.
3. **Session plane** — one `AarisSession` Durable Object owns each session's participants, deadlines, state, signaling sequence, and replay window.
4. **Signaling plane** — authenticated HTTP publish plus hibernatable WebSocket delivery/replay.
5. **Media plane** — MediaProjection -> WebRTC video track.
6. **Control plane** — ordered `control-v1` WebRTC DataChannel.
7. **Relay plane** — short-lived Cloudflare Realtime TURN credentials.

## Session state

Backend state is monotonic:

`CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_READY -> LIVE -> CLOSED`

Android additionally exposes `SCREEN_CONSENT` while the host is interacting with the operating-system MediaProjection prompt.

Repeated forward publications are idempotent. Backward transitions are rejected.

## Pairing

A share request creates:

- random 12-digit one-time code
- random 256-bit session identifier
- random host token
- five-minute code deadline

`PairingDirectory` stores `SHA-256(code) -> sessionId + expiry`. The raw code is not persisted. Redeem atomically consumes the directory entry before attaching a controller.

The host and controller use independent opaque credentials. Only their SHA-256 hashes are stored in the session Durable Object.

## Signaling

SDP descriptions, ICE candidates, ICE-restart requests, and advisory presence are stored as a bounded append-only event log. Every event receives a monotonic sequence number.

A WebSocket connects with `after=<last sequence>`. The Durable Object sends the current session snapshot followed by any missing signaling events, then live events.

Android retains:

- `client-instance:epoch` negotiation IDs
- stale-generation rejection
- exact answer-to-offer correlation through `replyToNegotiationId`
- idempotent description redelivery
- candidate gating until the local description is published
- bounded retries
- bounded ICE restart/startup recovery

Transport truth remains WebRTC peer connectivity plus the ordered control DataChannel. Signaling reconnects alone do not declare the session dead.

## TURN

The deployed Worker `aaris-remote-ice` now owns the full Cloudflare control plane. Its existing Worker secret bindings hold the long-lived Cloudflare Realtime TURN credentials.

TURN issuance is allowed only when:

- the caller presents a valid host/controller session token, and
- backend state is `SCREEN_READY` or `LIVE`.

The APK receives only short-lived ICE credentials.

## Android security boundary

The sharing phone alone requires Accessibility. The controller cannot execute Android gestures locally on behalf of the host.

The sharing phone must also grant MediaProjection through the Android system prompt. A visible STOP control remains available throughout connecting/live sharing.

## Build boundary

The Android project has no backend credential file. Release builds do not depend on a runtime-specific JSON configuration file. Backend secrets are Cloudflare Worker bindings and are not committed or packaged in the APK.
