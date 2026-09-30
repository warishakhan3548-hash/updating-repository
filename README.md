# Aaris Remote

A native Android remote-support app with a deliberately tiny user interface and a strict visible-session security model.

## Product contract

- Home stays simple: only Connect and Share are primary actions.
- Share creates the one-time code immediately; Accessibility setup is requested only after the sharing phone explicitly taps START, then the flow resumes automatically on return.
- Accessibility never grants unattended remote access by itself.
- Every screen-share session uses Android's MediaProjection consent.
- A sharing phone explicitly approves every new controller request.
- Pairing codes are five-minute, single-controller and one-time; shared messages also carry an `aarisremote://connect` join link that prefills the code but still requires START.
- A visible foreground notification and accessibility STOP overlay remain available while screen sharing connects and during live control.
- No hidden sessions, credential/OTP harvesting, or permission bypasses.
- Live control supports tap, long-press, swipe, Back, Home, Recents, and explicit text entry into the currently focused non-password field.
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
7. Recovery plane: transient post-connect network drops trigger a bounded ICE restart; control still expires fail-closed if heartbeats do not recover.
8. Pairing consistency: code reservation and session transition are transaction-guarded so a concurrent close cannot resurrect a session.

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

Aaris Remote 0.7.0 asks the `asia-south1` callable `getIceConfig` for ICE servers before signaling starts. The function always returns STUN servers and can also mint short-lived coturn REST credentials without storing a permanent TURN password in the APK.

Configure these environment values on the deployed Functions runtime:

- `TURN_URLS`: comma-separated TURN/TURNS URLs, for example `turn:relay.example.com:3478?transport=udp,turns:relay.example.com:5349?transport=tcp`
- `TURN_SHARED_SECRET`: the coturn REST shared secret, at least 16 characters and never committed to this repository

If TURN is not configured or the ICE-config call fails, the Android client falls back to the built-in STUN list. For production, run at least UDP TURN plus TLS/TCP TURN on a reachable relay and rotate the shared secret through your deployment secret store.
