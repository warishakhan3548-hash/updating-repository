# Aaris Shield architecture

## Step 1 — foundation

The app entry point depends on narrow shield modules. `:core:foundation` owns stable subsystem identifiers and process-local health snapshots. Protection layers remain independently owned so failure of one layer does not silently disable unrelated layers.

## Step 2 — Network / Domain Shield

Dependency direction is now:

`app -> core:network -> core:foundation`

The network module implements a local `VpnService` used only as a DNS interception boundary. It creates a private IPv4 TUN interface with a synthetic DNS server and routes only that single DNS address into the VPN. Ordinary application traffic is not routed through Aaris Shield, and there is no TLS interception, certificate installation, HTTP proxying, or payload inspection.

### DNS policy pipeline

1. Android sends ordinary VPN DNS queries to `10.111.222.1`.
2. The TUN reader accepts bounded, unfragmented IPv4/UDP DNS packets only.
3. Domain names are canonicalized with IDN/ASCII rules and checked against an offline suffix policy.
4. Explicit allow rules take precedence over deny rules.
5. Blocked names receive a local NXDOMAIN response.
6. Allowed queries are forwarded only to DNS servers reported by a validated/non-VPN underlying Android network. Upstream sockets are protected from the VPN loop and bound to that underlying network.
7. Returned CNAME, DNAME, SVCB and HTTPS alias targets are checked before the response is released. A blocked alias causes the original query to receive NXDOMAIN.
8. Malformed queries, invalid responses, missing upstream DNS, queue saturation, or upstream timeouts return SERVFAIL where a safe DNS response can be formed.

The worker pool is fixed at two workers with a maximum of 32 queued queries. This prevents unbounded memory growth if DNS arrives faster than upstream resolution.

### Lifecycle and failure behavior

The service records whether the user requested protection and returns `START_STICKY`, allowing Android to recreate it after ordinary process/service loss. It tracks non-VPN networks and DNS servers as connectivity changes, closes resources on revoke/destroy, and never falls back to a hard-coded public resolver when system DNS is unavailable.

The module deliberately opts out of Android always-on VPN in Step 2. This is a DNS-only partial tunnel; advertising lockdown support could cause non-DNS traffic to be blocked by Android even though Aaris Shield does not forward that traffic. Reboot/lockdown lifecycle hardening belongs to later lifecycle work after the tunnel architecture can safely support it.

The foreground service declares the Android 14+ `systemExempted` type used by VPN apps and promotes the service only after the VPN interface is established. The user must first grant Android's VPN consent through `VpnService.prepare()`.

### Offline rules

A small built-in seed denylist provides immediate blocking without network access. The rule parser also accepts hosts-file and simple adblock-domain syntax so a larger reviewed offline list can replace/extend the seed later without changing the matching algorithm. Domain suffix matching is label-boundary aware; `notblocked.example` does not match `blocked.example`.

Medical/educational domains can be explicitly allowlisted. No browsing history or DNS log is persisted.

## Known Step 2 limits

This layer is intentionally not described as universal network protection:

- Applications that implement their own encrypted DNS (DoH/DoT) or connect directly to hard-coded IP addresses can bypass a DNS-only VPN.
- HTTP/HTTPS URL paths and HTTP 3xx redirects are invisible without application cooperation or TLS interception; Aaris Shield does not perform TLS interception.
- DNS-over-TCP fallback is not implemented in this step. The local resolver handles UDP DNS up to the TUN MTU and forwards responses up to 4096 bytes; an upstream response requiring TCP retry can fail with normal DNS failure behavior.
- The seed denylist is intentionally small and should later be replaced or supplemented by a reviewed, licensed, versioned offline dataset.
- Full reboot, OEM-kill and lockdown-mode resilience is deferred to the dedicated reliability/lifecycle roadmap step.

## Platform baseline

- Kotlin source, Java 17 bytecode target.
- Android Gradle Plugin 9.4.0.
- `compileSdk` / `targetSdk` 36 (Android 16).
- `minSdk` 26 (Android 8.0).
- No cloud dependency in the network safety path.

## Research anchors

Primary Android documentation reviewed for Steps 1–2:

- Android app architecture: https://developer.android.com/topic/architecture
- Android modularization: https://developer.android.com/topic/modularization
- VpnService API: https://developer.android.com/reference/android/net/VpnService
- Android VPN developer guide: https://developer.android.com/develop/connectivity/vpn
- Foreground service types: https://developer.android.com/develop/background-work/services/fgs/service-types
- Android network state / LinkProperties: https://developer.android.com/develop/connectivity/network-ops/reading-network-state
