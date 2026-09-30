# Aaris Remote

A native Android remote-support app focused on a two-action UX and a strict visible-session security model.

## Product rules

- Native Kotlin / Android APIs for the control path.
- One-time accessibility setup; the service never accepts remote commands without an active approved session.
- Every screen-share session uses Android's MediaProjection consent.
- Pairing codes are short-lived and single-use.
- Screen media and control traffic use WebRTC; Firebase is only identity, pairing, signaling and presence.
- No hidden/unattended session mode and no credential/OTP harvesting.
- The remote phone always has a visible LIVE/STOP affordance.

## Stack

- Android Gradle Plugin 9.4 / JDK 17 / API 37
- Firebase Auth, Functions, Realtime Database, App Check
- WebRTC Android SDK
- AccessibilityService gesture executor
- MediaProjection foreground service

Firebase project configuration is intentionally not committed. Add `app/google-services.json` only through a secure local/CI secret workflow before enabling the deployed backend.
