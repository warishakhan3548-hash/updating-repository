# Aaris Remote

Aaris Remote is a native Android remote-support app. The sharing phone explicitly enables Accessibility and grants Android screen-capture permission; the controller phone does not need Accessibility.

## 1.8 architecture

Aaris Remote 1.8 uses Cloudflare as its complete internet control plane:

- **Pairing/session authority:** SQLite-backed Durable Objects.
- **One-time pairing:** random 12-digit code, five-minute expiry, single redemption.
- **Signaling:** hibernatable Cloudflare WebSockets with a bounded sequence replay log for SDP/ICE recovery.
- **TURN:** short-lived Cloudflare Realtime TURN credentials, available only to authenticated participants after `SCREEN_READY`.
- **Media/control:** direct WebRTC between the phones; ordered `control-v1` DataChannel carries remote commands.
- **Android state:** deterministic local state machine remains the UI/lifecycle authority on each phone.

Firebase is not used by the Android runtime, build, pairing, signaling, session state, or TURN authorization.

## Session flow

Local/UI flow:

`IDLE -> READY -> CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_CONSENT -> CONNECTING -> LIVE -> CLOSED`

Cloudflare authoritative states:

`CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_READY -> LIVE -> CLOSED`

Backend transitions are monotonic and idempotent for already-completed forward states.

## Security

The 12-digit code is stored only as a SHA-256 lookup key inside the private pairing Durable Object and is deleted on redemption. Host and controller get independent random opaque session tokens; only SHA-256 token hashes persist in the session Durable Object. TURN account secrets remain Cloudflare Worker secrets and never ship in the APK.

Screen frames and remote-control commands are not proxied through the Worker. They stay on the WebRTC peer connection.

## Reliability

Signaling events receive monotonic sequence numbers. A reconnecting WebSocket requests replay after its last sequence so a short signaling disconnect does not silently lose SDP/ICE state. Android keeps bounded SDP/candidate retries and bounded ICE-restart/relay escalation. Transport truth remains the WebRTC peer plus ordered DataChannel.

## Build

No `google-services.json` or Firebase build secret is required.

GitHub CI runs unit tests, debug/release lint, debug/release assembly, and a live Cloudflare backend smoke test. Codemagic can create the signed release APK using the configured Android signing identity.


### 1.8.6 no-video recovery hardening

- **Missing-track recovery:** once the controller receives the authenticated WebRTC/control HELLO, it now starts bounded video recovery even if Android/libwebrtc never delivers the initial remote `VideoTrack` callback.
- This closes the remaining state where both phones could be connected and controllable while the controller stayed on “waiting for screen video” forever.
- Cloudflare Worker signaling/TURN configuration is unchanged because account-side telemetry shows successful ICE credential responses and healthy Durable Object/WebSocket infrastructure.

### 1.8.5 connectivity hardening

- **Controller waiting room:** entering a pairing code no longer opens the heavy WebRTC viewer before the sharing phone has approved MediaProjection. The controller stays in-app until Cloudflare reports `SCREEN_READY`.
- **Lazy remote renderer:** the controller's EGL-backed `SurfaceViewRenderer` is initialized only after a real remote video track exists, reducing OEM/GPU lifecycle risk during the pairing handoff.
- Existing relay-first Cloudflare TURN startup, replay-safe signaling, capture first-frame checks, and bounded recovery remain enabled.
