# Architecture

## Planes

1. **Session plane** — strict local state machine and fail-closed session guard.
2. **Pairing plane** — Firebase Anonymous Auth + Realtime Database using a 12-digit, five-minute, one-time code. Only the SHA-256 lookup key is stored in RTDB.
3. **Signaling plane** — participant-scoped SDP/ICE exchange through the Singapore Realtime Database.
4. **Media plane** — MediaProjection -> WebRTC video track -> controller renderer.
5. **Control plane** — ordered WebRTC DataChannel messages -> generation-aware coordinate mapping -> AccessibilityService gestures.
6. **Safety plane** — no valid LIVE lease means no gesture execution; STOP, lease expiry, Accessibility loss, projection stop, or transport failure revokes local control.
7. **Transport-truth plane** — the controller is usable only when both the WebRTC peer and the ordered `control-v1` DataChannel are ready.
8. **Deadline plane** — code discovery, host approval, and screen/transport setup use separate deadlines.

## Session states

`IDLE -> SETUP_REQUIRED -> READY -> CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_CONSENT -> CONNECTING -> LIVE -> CLOSED`

Every local transition is monotonic for a session. A closed local state machine is replaced only when starting a new session.

## Pairing consistency

Share-ticket creation writes the code reservation and session record as one RTDB multi-location update. Controller claim and host state transitions use RTDB transactions so simultaneous redeems or stale clients cannot legitimately advance the same session twice.

The app uses the explicit database endpoint:

`https://aaris-control-default-rtdb.asia-southeast1.firebasedatabase.app`

This avoids relying on whether an older `google-services.json` happened to contain a Realtime Database URL.

## Pairing deadlines

`CODE_ACTIVE` has a five-minute discovery lifetime. A successful controller claim creates a fresh three-minute `PAIR_PENDING` approval window. Host approval creates a separate three-minute screen/transport setup window.

## Transport readiness

WebRTC peer connectivity alone is not treated as usable remote control. The controller becomes connected only when both peer connectivity and the ordered control channel are ready. The host keeps an initial transport watchdog armed until that condition is met.

## Recovery

After a previously-live peer disconnects, the host performs a bounded ICE restart. The Spark build intentionally uses public Google STUN servers and does not depend on Cloud Functions or billing-backed TURN credential minting.

STUN-only operation works on many ordinary Wi-Fi and mobile networks, but restrictive carrier-grade or symmetric NAT can still require a separately operated TURN relay for high connection coverage.

## Coordinate policy

Controller touches are mapped through the actual rendered video rectangle rather than the whole local display. Letterbox bars are ignored. The controller also compares the received video-frame aspect ratio with the current remote display geometry and temporarily rejects touches during stale portrait/landscape transitions.

Normalized coordinates are bound to a display generation. Rotation bumps the generation once a live lease exists, invalidating stale control packets.

## Local-control liveness

The host creates a short-lived local lease only after peer + control channel are ready. Heartbeats renew that lease. If the lease expires or Android removes the AccessibilityService, the host fails closed.

## Accessibility execution

WebRTC callbacks may arrive off the Android main looper, so remote commands are serialized onto the AccessibilityService main handler before gesture, global-action, or focused-text APIs are invoked.

Direct remote text entry is limited to a focused editable non-sensitive field. Android password input types and local metadata hints such as password, OTP, verification code, UPI/ATM PIN, CVV/CVC, and similar credential fields are rejected. Postal PIN-code metadata is not treated as a credential by metadata alone.

## Media policy

The screen sender prefers maintaining frame cadence under congestion and caps its video envelope. WebRTC may lower bitrate or resolution to preserve interaction responsiveness.

## Multi-touch

Two controller pointers are encoded in one generation-bound packet and replayed as simultaneous Accessibility strokes, supporting pinch/zoom and two-finger pan without splitting them into unrelated gestures.

## Visible-session contract

Every host session requires:
- explicit pairing acceptance,
- Accessibility enabled by the sharing user,
- Android MediaProjection consent for that session,
- a visible foreground notification,
- and an Accessibility `STOP • SHARING` overlay.

The app does not bypass Android secure windows or the device lock screen. Remote commands are rejected while the sharing phone is locked.

## Firebase / Spark boundary

The core flow uses Firebase Anonymous Auth + Realtime Database on the Spark plan. Cloud Functions, Firebase Messaging, App Check, and Google sign-in are not required by the current runtime.

RTDB is used only for pairing/session metadata, presence, and SDP/ICE signaling. Video and control payloads travel peer-to-peer over WebRTC.
