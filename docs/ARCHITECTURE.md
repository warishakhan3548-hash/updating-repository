# Aaris Shield architecture

## Current implemented boundary

Step 1 established the minimal Android foundation and independent subsystem identities. Step 2 adds the first real protection subsystem: a local Network / Domain Shield. Later visual, overlay, accessibility, OCR, audio, calibration, privacy, and performance layers remain unimplemented and must continue as separate numbered upgrades.

The visible app remains intentionally small. Platform-sensitive behavior lives outside the `Activity`.

## Dependency direction

- `app -> core:foundation`
- `app -> core:network`

`:core:foundation` remains Android-free at the Kotlin source level so shared health/state rules stay deterministic and unit-testable. `:core:network` owns Android VPN/DNS behavior plus pure-Kotlin domain/DNS packet policy code. Future modules must not reach into another subsystem's implementation details.

## Step 2 network boundary

The Network Shield uses Android `VpnService` only as a DNS interception surface:

1. Android VPN consent is requested through `VpnService.prepare()`.
2. The TUN interface advertises one synthetic IPv4 DNS resolver.
3. Only that resolver's `/32` address is routed into the TUN interface; ordinary application traffic is not proxied by Aaris Shield.
4. DNS questions are normalized and checked against an offline exact/suffix blocklist with a most-specific allowlist override.
5. Allowed queries are resolved on an underlying non-VPN network.
6. API 29+ uses Android `DnsResolver.rawQuery()` so the platform resolver path remains authoritative.
7. API 26-28 uses the underlying network's advertised DNS servers. On API 28, if Private DNS is active, Step 2 fails closed rather than silently downgrading it to plaintext UDP.
8. CNAME, DNAME, SVCB, and HTTPS alias targets are inspected before a response is returned. A blocked alias produces a local NXDOMAIN response.
9. Malformed, truncated, timed-out, or queue-overflow cases return SERVFAIL where a valid DNS question is available.
10. Upstream DNS names, packet payloads, and browsing history are never logged or persisted.

The service uses a bounded worker queue and `START_STICKY` recovery for an unexpected process/service restart while the user-requested state remains enabled.

## Permission policy

Step 2 adds only permissions justified by the Network Shield:

- `INTERNET` for allowed DNS resolution.
- `ACCESS_NETWORK_STATE` to choose a physical non-VPN network.
- `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_SPECIAL_USE` for the long-running VPN service on current Android.
- `BIND_VPN_SERVICE` protects the service component and is held by the Android system, not requested as a runtime permission from the user.

No accessibility, screen-capture, overlay, microphone, storage, location, contacts, or boot permission is introduced in Step 2.

## Always-on and lockdown decision

`SUPPORTS_ALWAYS_ON=false` is deliberate in Step 2. This implementation is a DNS-only split-tunnel, not a full traffic-forwarding VPN. Advertising always-on/lockdown support before full non-DNS forwarding could turn Android's lockdown behavior into a device-wide connectivity failure. Reliability hardening can revisit this only if the architecture can preserve ordinary traffic safely.

## Current platform baseline

- Kotlin source, Java 17 bytecode target.
- Android Gradle Plugin 9.4.0.
- `compileSdk` / `targetSdk` 36 (Android 16).
- `minSdk` 26 (Android 8.0), with explicit API gating for newer DNS APIs.
- Core safety behavior remains local-first with no cloud classification dependency.

## Safety invariants

1. A network failure does not imply visual/audio/other subsystem state changes.
2. Domain decisions are based on curated domains, not attractiveness, gender, or skin exposure.
3. The Network Shield does not perform TLS interception, install a CA, or inspect HTTPS payloads.
4. Queue growth is bounded; overload returns DNS failure rather than allocating without limit.
5. Malformed DNS never bypasses alias inspection by default.
6. Raw DNS traffic is not recorded.
7. Explicit allow rules can override a blocked parent only when they are at least as specific; a more specific block still wins.

## Research anchors

Primary Android documentation reviewed for the implemented boundary:

- VPN developer guide: https://developer.android.com/develop/connectivity/vpn
- `VpnService`: https://developer.android.com/reference/android/net/VpnService
- `VpnService.Builder`: https://developer.android.com/reference/android/net/VpnService.Builder
- `DnsResolver`: https://developer.android.com/reference/android/net/DnsResolver
- Foreground-service types: https://developer.android.com/develop/background-work/services/fgs/service-types
- Foreground-service changes: https://developer.android.com/develop/background-work/services/fgs/changes
- Insecure DNS setup guidance: https://developer.android.com/privacy-and-security/risks/bad-dns
