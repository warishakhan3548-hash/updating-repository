# Aaris Remote

A native Android remote-support app with a deliberately tiny user interface and a strict visible-session security model.

## Product contract

- Home stays simple: only Connect and Share are primary actions, now presented in a polished blue/white support surface with a live status card rather than raw platform-default controls.
- Busy pairing/setup/reconnect phases expose an indeterminate progress indicator instead of looking frozen; idle, live, and terminal states settle back to a calm status surface.
- Android 13+ notification permission is requested just-in-time after the sharing phone explicitly approves remote support, never as first-launch friction; denial does not bypass the always-visible in-app accessibility STOP overlay.
- Share creates the one-time code immediately; the Android share handoff is crash-safe and falls back to copying the complete invite when a share target cannot be opened. Accessibility setup is requested only after the sharing phone explicitly taps START, then the flow resumes automatically on return.
- Connect can recover the same unique 12-digit code even when the receiver copied the entire shared Aaris Remote message, while refusing ambiguous clipboard text that contains different candidate codes.
- Accessibility never grants unattended remote access by itself.
- Every screen-share session uses Android's MediaProjection consent.
- A sharing phone explicitly approves every new controller request.
- Pairing codes are five-minute, single-controller and one-time; after a valid redeem, the host gets a fresh three-minute approval window, followed by a separate three-minute screen/setup window. Shared messages also carry an `aarisremote://connect` join link that tolerates safe URI normalization, prefills the code, and still requires START.
- A visible foreground notification and accessibility STOP overlay remain available while screen sharing connects and during live control.
- No hidden sessions, credential/OTP harvesting, or permission bypasses.
- Live control supports tap, long-press, path-aware swipe/drag, true two-finger gestures (including pinch/zoom and two-finger pan), Back, Home, Recents, and explicit text entry into the currently focused non-sensitive field.
- Controller controls can collapse to a small Controls handle, exposing the full remote canvas so bottom-of-screen targets are not hidden behind the local control dock.
- Touch mapping uses the actual rendered-frame aspect and rejects transient stale rotation geometry instead of risking a tap on the wrong remote target.
- Remote actions now report host-side execution truth over the same ordered control channel: completed Accessibility gestures clear normally, while rejected or cancelled actions use the existing status surface instead of silently looking successful.
- Password, OTP, PIN, verification-code, CVV/CVC and similar sensitive fields remain local to the sharing phone; remote direct-text injection does not populate them.
- Commands are rejected while the sharing phone is locked.

## Native stack

- Android API 36 / AGP 9.4 / Gradle 9.6 / JDK 17
- Kotlin-first native Android UI and services
- Firebase Anonymous Auth + Realtime Database on the Spark plan
- WebRTC Android SDK for media and control transport
- AccessibilityService for user-approved remote gestures
- MediaProjection foreground service for screen capture

## Internal planes

1. Session state machine: fail-closed state transitions.
2. Pairing plane: the two authenticated clients coordinate through RTDB using a 12-digit one-time code whose SHA-256 hash is the lookup key.
3. Signaling plane: RTDB carries participant-scoped SDP/ICE only.
4. Media plane: MediaProjection -> WebRTC video track.
5. Control plane: WebRTC DataChannel -> command gate -> AccessibilityService.
6. Safety plane: expiring local live lease + sequence/generation checks + STOP/revoke.
7. Recovery plane: transient post-connect network drops trigger a bounded ICE restart; duplicate ICE/peer callbacks are collapsed into one connectivity truth and pre-connect presence noise cannot falsely start the reconnect timer.
8. Control-channel safety: a closed WebRTC DataChannel immediately leaves the control plane and is given only a short recovery grace before the sharing session fails closed.
9. Pairing consistency: code reservation and session transition are atomic and transaction-guarded; failed session creation or controller bootstrap rolls back its reservation instead of leaving a poisoned pending request.
10. ICE configuration: Spark builds use provider-diverse public STUN (Google + Cloudflare) for direct-path discovery; no billing-backed relay credential service is required.
11. Transport truth: controller UI reports connected only when both the WebRTC peer and ordered control DataChannel are ready; losing either plane leaves connected state immediately.
12. Deadline isolation: code discovery, host approval, and screen/transport setup use separate backend deadlines so a code redeemed near expiry cannot collapse the consent/setup phase.
13. Local-control liveness: if Android removes or disables the active AccessibilityService during a LIVE session, the host fails closed instead of continuing a view-only session that appears controllable.
14. Interaction-first media: the screen-video sender prefers maintaining frame cadence under congestion and caps its send envelope so touch feedback stays responsive while WebRTC adapts resolution as needed.
15. Multi-touch control: two controller fingers are transported as one generation-bound command and replayed as simultaneous Accessibility strokes, enabling pinch/zoom and two-finger navigation without layering hidden input paths.
16. Serialized accessibility dispatch: remote commands are executed on the AccessibilityService main looper, and a stale destroyed service instance cannot clear a newer connected instance.
17. Frictionless code recovery: Connect extracts one unique 12-digit pairing code from copied share text, but does not guess when multiple different candidate codes are present.
18. ICE-restart recovery: transient network drops reuse the current STUN configuration and restart ICE without a Cloud Functions dependency.
19. Gesture fidelity: bounded MotionEvent history is sent as one display-generation-bound path, preserving curved drags and fast pans while discarding rotation-stale gestures.
20. Share handoff resilience: if Android cannot open a share target, the complete invite is copied locally and the existing session remains usable without another setup screen.
21. Controller terminal-state handoff: connection loss, setup expiry, and transport-start failures return a clear reason to the existing home status surface instead of leaving stale pairing text behind.
22. Offline fast-fail: Connect and Share reject an obviously unavailable network before starting Firebase work, while the existing backend timeouts remain the authority for uncertain network states.
23. Command execution truth: the host acknowledges each sequenced remote action only after Android accepts or completes it; cancellations and safety rejections are returned to the controller without adding another control surface.
24. Captive-portal awareness: an explicitly captive Wi-Fi network is rejected up front, while merely unvalidated routes are still allowed to reach the bounded Firebase/WebRTC timeouts.
25. Ordered remote execution: accessibility commands are executed one at a time with a bounded queue, preventing a rapid tap/swipe sequence from cancelling the gesture already in progress; stale result acknowledgements are ignored without adding any new UI.
26. Startup ICE recovery: one bounded pre-live host ICE restart is attempted after an initial WebRTC transport failure or a short pre-live DISCONNECTED stall, while the controller keeps listening for the retry offer until the existing handshake timeout decides the session is unrecoverable.
27. Edge-continuous gestures: a gesture must start inside the rendered remote screen, but an already-valid swipe or pinch may drift into local letterbox space and is clamped to the nearest remote edge instead of being silently discarded.
28. Join-link ambiguity guard: deep links accept exactly one pairing-code parameter and reject unexpected authority/fragment forms so malformed shared links cannot select an unintended code.
29. Signaling/transport separation: Firebase presence is advisory only; a transient RTDB presence drop cannot tear down an otherwise healthy WebRTC peer plus ordered control channel.

## Firebase setup

Aaris Remote is designed to run on Firebase's Spark plan without Cloud Functions.

1. Firebase project: `aaris-control`.
2. Android package: `com.aaris.remoteassist`.
3. Anonymous Authentication must be enabled.
4. Realtime Database must exist in `asia-southeast1`.
5. Deploy the repository's `database.rules.json`; it is the authorization boundary for pairing, session state, signaling, and presence.
6. Codemagic restores `google-services.json` from secure variable `GOOGLE_SERVICES_JSON_B64` and verifies both the project ID and Android package before the release build.
7. Pairing codes are 12 digits, one-time, five-minute credentials. The database stores only the SHA-256 lookup key rather than the raw code.

No Firebase billing account, Cloud Functions, App Check, Firebase Messaging, or Google sign-in is required for the core remote-support flow.

## Network reliability

The Spark build uses provider-diverse public STUN servers for WebRTC NAT traversal. This keeps the core app free of billing-backed infrastructure, avoids a single STUN-provider dependency, and works on many ordinary Wi-Fi/mobile-network combinations.

A TURN relay is still the standard way to improve connection coverage on restrictive carrier-grade or symmetric NATs. Because TURN requires a reachable relay service, the current Spark-only build intentionally treats it as an optional future deployment rather than requiring Firebase billing.

The control and video paths remain WebRTC peer transport; RTDB is used only for pairing/session state and SDP/ICE signaling.
