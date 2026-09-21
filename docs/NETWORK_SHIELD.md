# Step 2 — Network / Domain Shield

## What it does

The Step 2 Network Shield is a local DNS policy layer built on Android `VpnService`. It creates a synthetic DNS endpoint inside the VPN interface and routes only that address into the TUN. Normal web/app traffic continues over Android's ordinary network stack.

For each supported UDP DNS query:

- normalize the queried hostname using IDNA/STD3 rules;
- apply the bundled allow/block policy with most-specific-rule-wins semantics;
- answer blocked names locally with NXDOMAIN;
- forward allowed names using Android's resolver path on API 29+;
- on API 26-28, use only DNS servers advertised by the selected underlying network;
- reject an API 28 fallback when Private DNS is active rather than downgrading resolver transport;
- inspect CNAME, DNAME, SVCB, and HTTPS target names in replies;
- replace a reply that aliases into a blocked domain with NXDOMAIN;
- return SERVFAIL for malformed/truncated/upstream-failure cases when possible.

The bundled domain file is deliberately a small offline seed, not a claim of comprehensive adult-site coverage. It can be expanded later with a separately reviewed, license-compatible source without changing the policy engine.

## Redirect handling

HTTP redirects to another hostname naturally trigger a later DNS query, which is filtered normally. DNS-level indirection is also checked directly: CNAME, DNAME, SVCB, and HTTPS target names are parsed before a response is injected back into Android.

## Resource and lifecycle behavior

- DNS work uses a bounded 2-to-4-thread pool with a queue of 64 requests.
- Queue overflow fails the query with SERVFAIL instead of growing memory indefinitely.
- The TUN reader is blocking and isolated from upstream DNS work.
- A closed TUN descriptor triggers a bounded restart attempt while the stored user-requested state remains enabled.
- User stop and VPN permission revocation close the descriptor and clear requested state.
- No DNS query hostname or packet payload is written to logs or preferences.

## Explicit limitations

This step does not claim universal network blocking.

- Android permits only one VPN app per user/profile, so enabling Aaris Shield's Network Shield displaces another active VPN and vice versa.
- Apps that implement their own DNS-over-HTTPS/DNS-over-TLS or connect to hardcoded IP addresses can bypass this DNS-only policy because their traffic is not routed into the TUN.
- Existing DNS caches and already-open connections are not retroactively terminated.
- TCP DNS to the synthetic resolver is not implemented in Step 2. If an upstream response is truncated, the proxy returns SERVFAIL rather than bypassing policy. This can cause rare legitimate resolution failures.
- The implementation does not inspect URL paths, HTTPS payloads, ECH/SNI, images, video, or audio.
- Always-on/lockdown VPN support is deliberately disabled until a future architecture can guarantee that a DNS-only split tunnel will not break non-DNS connectivity.
- The bundled blocklist is a seed list and is not exhaustive.

These limits are why later independent visual, screen, OCR, audio, cover, strict-mode, calibration, privacy, and reliability layers remain necessary.
