# Aaris Remote

A native Android remote-support app with a deliberately tiny user interface and a strict visible-session security model.

## Product contract

- Home stays simple: enter one-time code + Connect, or Share my phone.
- Accessibility is a one-time setup, but it never grants unattended remote access by itself.
- Every screen-share session uses Android's MediaProjection consent.
- A sharing phone explicitly approves every new controller request.
- Pairing codes are short-lived, single-controller and one-time.
- A visible foreground notification and accessibility STOP overlay remain available during live control.
- No hidden sessions, credential/OTP harvesting, or permission bypasses.

## Native stack

- Android API 37 / AGP 9.4 / Gradle 9.6 / JDK 17
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

## Firebase setup

The repository intentionally does not contain a Firebase project credential.

1. Register Android app `com.aaris.remoteassist` in Firebase.
2. Put `google-services.json` at `app/google-services.json`.
3. Enable Anonymous Authentication and Realtime Database.
4. Create the Functions secret `PAIRING_PEPPER` with a strong random value.
5. Deploy Cloud Functions and Realtime Database rules.
6. Enable App Check / Play Integrity for production builds.

The Gradle Google Services plugin is applied only when `google-services.json` exists, so CI can still compile the source tree without committing credentials.
