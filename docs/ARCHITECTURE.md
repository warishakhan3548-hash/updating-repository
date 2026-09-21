# Aaris Shield architecture foundation

## Step 1 boundary

This repository starts from an intentionally small Android foundation. Step 1 does **not** claim that any content protection is active. It adds only the structure required for later, separately verified shield layers.

The app module is an Android entry point. `:core:foundation` is deliberately Android-free at the Kotlin source level so core health/state rules stay deterministic and unit-testable. Platform-specific services will live behind their own future module boundaries instead of accumulating inside an `Activity`.

## Dependency direction

`app -> core:foundation`

Future protection modules may depend on `core:foundation`; they must not depend on each other's implementation details. Cross-layer coordination should happen through narrow state/contracts so one failed subsystem does not automatically disable every other subsystem.

## Permission policy

Step 1 requests no VPN, accessibility, screen-capture, overlay, microphone, notification, boot, or foreground-service permissions. Sensitive permissions are added only in the step that implements the capability and can justify its lifecycle and failure behavior.

This is especially important because modern Android applies explicit restrictions to foreground services, MediaProjection, AccessibilityService, and VPN lifecycles. Architecture must follow platform consent surfaces rather than simulate capabilities the OS does not provide.

## Current platform baseline

- Kotlin source, Java 17 bytecode target.
- Android Gradle Plugin 9.4.0.
- `compileSdk` / `targetSdk` 36 (Android 16).
- `minSdk` 26 (Android 8.0), with future newer-API features required to use explicit runtime/API gating.
- No cloud dependency in the core safety foundation.

## Future subsystem ownership

Stable identifiers are reserved for network, visual classification, region localization, overlay, screen observation, text safety, audio safety, safety cover, strict mode, calibration, and privacy/performance. Reserving identifiers is not an implementation claim; the progress file is authoritative about what exists.

## Safety invariants established now

1. Component state updates are isolated by subsystem identifier.
2. Duplicate initial subsystem ownership is rejected.
3. Callers receive snapshot copies instead of mutable live registry views.
4. UI explicitly states that protection modules are not enabled yet.
5. No sensitive Android permission is introduced before the corresponding implementation step.

## Research anchors

Primary Android documentation reviewed for this foundation:

- Android app architecture: https://developer.android.com/topic/architecture
- Android modularization: https://developer.android.com/topic/modularization
- AGP 9 built-in Kotlin: https://developer.android.com/build/migrate-to-built-in-kotlin
- AGP 9.4 compatibility: https://developer.android.com/build/releases/agp-9-4-0-release-notes
- Android 16 SDK setup: https://developer.android.com/about/versions/16/setup-sdk
- Foreground-service types: https://developer.android.com/develop/background-work/services/fgs/service-types
- VpnService: https://developer.android.com/reference/android/net/VpnService
- AccessibilityService screenshots: https://developer.android.com/reference/android/accessibilityservice/AccessibilityService
