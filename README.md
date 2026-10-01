# Aaris Remote

A native Android remote-support app with a deliberately tiny user interface and a strict visible-session security model.

## Product contract

- Home stays simple: only Connect and Share are primary actions, now presented in a polished blue/white support surface with a live status card rather than raw platform-default controls.
- Busy pairing/setup/reconnect phases expose an indeterminate progress indicator instead of looking frozen; idle, live, and terminal states settle back to a calm status surface.
- Android 13+ notification permission is requested just-in-time after the sharing phone explicitly approves remote support, never as first-launch friction; denial does not bypass the always-visible in-app accessibility STOP overlay.
- Share creates the one-time code immediately; Accessibility setup is requested only after the sharing phone explicitly taps START, then the flow resumes automatically on return.
- Connect can recover the same unique six-digit code even when the receiver copied the entire shared Aaris Remote message, while refusing ambiguous clipboard text that contains different candidate codes.
- Accessibility never grants unattended remote access by itself.
- Every screen-share session uses Android's MediaProjection consent.
- A sharing phone explicitly approves every new controller request.
- Pairing codes are five-minute, single-controller and one-time; after a valid redeem, the host gets a fresh three-minute approval window, followed by a separate three-minute screen/setup window. Shared messages also carry an `aarisremote://connect` join link that prefills the code but still requires START.
- A visible foreground notification and accessibility STOP overlay remain available while screen sharing connects and during live control.
- No hidden sessions, credential/OTP harvesting, or permission bypasses.
- Live control supports tap, long-press, swipe, true two-finger gestures (including pinch/zoom and two-finger pan), Back, Home, Recents, and explicit text entry into the currently focused non-sensitive field.
- Controller controls can collapse to a small Controls handle, exposing the full remote canvas so bottom-of-screen targets are not hidden behind the local control dock.
- Touch mapping uses the actual rendered-frame aspect and rejects transient stale rotation geometry instead of risking a tap on the wrong remote target.
- Password, OTP, PIN, verification-code, CVV/CVC and similar sensitive fields remain local to the sharing phone; remote direct-text injection does not populate them.
- Commands are rejected while the sharing phone is locked.

## Native stack

- Android API 36 / AGP 9.4 / Gradle 9.6 / JDK 17
- Kotlin-first native Android UI and services
- Firebase Anonymous Auth + App Check + Cloud Functions + Realtime Database
- WebRTC Android SDK for media and control transport
- AccessibilityService for user-approved remote gestures
- MediaProjection foreground service for screen capture

## Internal planes

1. Session state machine: fail-closed state transitions.
2. Pairing plane: Cloud Functions mint and redeem one-time codes.
3. Signaling plane: RTDB carries participant-scoped SDP/ICE only.
4. Media plane: MediaProjection -> WebRTC video track.
5. Control plane: WebRTC DataChannel -> command gate -> AccessibilityService.
6. Safety plane: expiring local live lease + sequence/generation checks + STOP/revoke.
7. Recovery plane: transient post-connect network drops trigger a bounded ICE restart; duplicate ICE/peer callbacks are collapsed into one connectivity truth and pre-connect presence noise cannot falsely start the reconnect timer.
8. Control-channel safety: a closed WebRTC DataChannel immediately leaves the control plane and is given only a short recovery grace before the sharing session fails closed.
9. Pairing consistency: code reservation and session transition are transaction-guarded; failed session creation or controller bootstrap rolls back its reservation instead of leaving a poisoned pending request.
10. Relay authorization: TURN/ICE configuration is issued only to an authenticated participant of that active SCREEN_READY/LIVE session.
11. Transport truth: controller UI reports connected only when both the WebRTC peer and ordered control DataChannel are ready; losing either plane leaves connected state immediately.
12. Deadline isolation: code discovery, host approval, and screen/transport setup use separate backend deadlines so a code redeemed near expiry cannot collapse the consent/setup phase.
13. Local-control liveness: if Android removes or disables the active AccessibilityService during a LIVE session, the host fails closed instead of continuing a view-only session that appears controllable.
14. Interaction-first media: the screen-video sender prefers maintaining frame cadence under congestion and caps its send envelope so touch feedback stays responsive while WebRTC adapts resolution as needed.
15. Multi-touch control: two controller fingers are transported as one generation-bound command and replayed as simultaneous Accessibility strokes, enabling pinch/zoom and two-finger navigation without layering hidden input paths.
16. Serialized accessibility dispatch: remote commands are executed on the AccessibilityService main looper, and a stale destroyed service instance cannot clear a newer connected instance.
17. Frictionless code recovery: Connect extracts one unique six-digit pairing code from copied share text, but does not guess when multiple different candidate codes are present.
18. Relay-refresh recovery: every host ICE restart refreshes its session-bound ICE/TURN configuration before restarting connectivity, so long-running sessions do not depend on stale relay credentials.

## Firebase setup

The repository intentionally does not contain a Firebase project credential.

1. Register Android app `com.aaris.remoteassist` in Firebase.
2. Put `google-services.json` at `app/google-services.json`.
3. Enable Anonymous Authentication and Realtime Database.
4. Create the Functions secret `PAIRING_PEPPER` with a strong random value.
5. Deploy Cloud Functions and Realtime Database rules.
6. Enable App Check / Play Integrity for production builds.
7. Debug builds use Firebase's App Check debug provider. Register the emitted debug token in the Firebase console for development devices; never commit that token.
8. For GitHub Actions APKs, optionally store base64-encoded `google-services.json` as the repository secret `GOOGLE_SERVICES_JSON_B64`; CI restores it only inside the runner and never commits it.

The Gradle Google Services plugin is applied only when `google-services.json` exists, so CI can still compile the source tree without committing credentials. Production builds use Play Integrity; debug builds use the Firebase debug provider, matching Firebase's recommended development flow.

## Production relay reliability

Direct WebRTC works well on many networks, but carrier-grade NAT and symmetric NAT require a TURN relay for TeamViewer-class connection reliability.

Aaris Remote 1.5.0 asks the `asia-south1` callable `getIceConfig` for ICE servers before signaling starts. The request is bound to the active session and accepted only for its host/controller while the transport is SCREEN_READY or LIVE. The function always returns STUN servers and can also mint short-lived coturn REST credentials without storing a permanent TURN password in the APK.

Configure the relay endpoint and secret on the deployed Functions runtime:

- `TURN_URLS`: comma-separated TURN/TURNS URLs, for example `turn:relay.example.com:3478?transport=udp,turns:relay.example.com:5349?transport=tcp`
- `TURN_SHARED_SECRET`: a Firebase Functions secret containing the coturn REST shared secret, at least 16 characters and never committed to this repository

Create or rotate the TURN secret before deploying Functions:

```bash
firebase functions:secrets:set TURN_SHARED_SECRET
```

If TURN URLs are not configured or the ICE-config call fails, the Android client falls back to the built-in STUN list. For TeamViewer-class connection coverage across restrictive carrier/symmetric NATs, deploy reachable UDP TURN plus TCP/TLS fallback and rotate the shared secret through the Functions secret store.
