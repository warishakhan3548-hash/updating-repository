# Aaris Remote

Aaris Remote is a native Android remote-support app with explicit host approval, Android screen-share consent, a persistent STOP control, WebRTC video, and an ordered remote-control DataChannel.

## 1.8 architecture

Aaris Remote 1.8 uses one Cloudflare control plane. The Android app no longer requires Firebase, `google-services.json`, Google Services Gradle plugins, Firebase Authentication, or Realtime Database.

### Session flow

`IDLE -> READY -> CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_CONSENT -> CONNECTING -> LIVE -> CLOSED`

Cloudflare authoritatively stores the remote portion:

`CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_READY -> LIVE -> CLOSED`

The Android-only `SCREEN_CONSENT` state represents the mandatory MediaProjection approval UI.

### Cloudflare components

- Worker deployment: `aaris-remote-ice`
- Worker source: `cloudflare/core-worker.js`
- Pairing lookup: SQLite-backed Durable Object `PairingDirectory`
- Per-session authority: SQLite-backed Durable Object `AarisSession`
- Signaling receive path: hibernatable WebSocket with sequence replay
- Signaling publish path: authenticated HTTP events with bounded client retry
- Relay: Cloudflare Realtime TURN
- Media/control transport: WebRTC between the two Android peers

The Worker name is retained from the earlier TURN-only deployment so the already-provisioned TURN secrets stay server-side. Its runtime role is now the complete Cloudflare control plane, not a separate Firebase bridge.

## Pairing and authorization

Share creates a random 12-digit one-time code with a five-minute TTL. The Worker stores only a SHA-256 lookup key in `PairingDirectory`, mapped to a random 256-bit session identifier.

The host and controller receive different random opaque session tokens. Durable Object storage keeps only SHA-256 token hashes. The raw pairing code and raw session tokens are not persisted server-side.

Redeeming a code consumes the directory entry before the controller is attached, preventing a second controller from claiming the same code.

## WebRTC signaling

Every signaling event has:

- a monotonic sequence number
- sender role
- event kind
- payload
- creation time

A reconnecting WebSocket supplies its last received sequence and the Durable Object replays the bounded missing event window before continuing live delivery.

Existing WebRTC negotiation protections remain in place: generation IDs, answer-to-offer correlation, stale-generation rejection, bounded description/candidate retries, bounded startup recovery, and relay preference escalation.

## TURN

The long-lived Cloudflare TURN key remains only in Worker secret bindings. After a session reaches `SCREEN_READY` or `LIVE`, either authenticated participant may request short-lived ICE credentials. The APK never contains the long-lived TURN secret.

If TURN temporarily cannot be loaded, WebRTC retains provider-diverse STUN fallback and the existing bounded recovery path.

## Android permissions

Accessibility is required only on the sharing/controlled phone because that phone executes gestures. The controller phone does not need Accessibility.

Screen capture always requires Android MediaProjection consent from the sharing phone.

## Build

Version 1.8.0 uses:

- `versionCode 48`
- `versionName 1.8.0`

No backend configuration file is injected into the APK. GitHub CI runs unit tests, debug/release lint, and debug/release assembly. Codemagic may sign release builds with the configured Android keystore.
