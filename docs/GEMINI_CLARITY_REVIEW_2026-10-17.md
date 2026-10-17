# Gemini proposal: verified findings and guarded integration

Audited base: `07f6e3b57748456d55628661a53448254ef1d4b3`,
`warishakhan3548-hash/updating-repository`. Reviewed the attached
`Upgrade Aaris Smoothness And Clarity.py` without executing it against the
repository. Its title/version is a proposal, not evidence of an existing release.

## Findings

| Proposal | Code/documentation finding | Decision |
| --- | --- | --- |
| Recover detail while a finger remains down | All three layers deliberately veto this: `PhotonFreshnessGovernor`, the host caller, and `MotionVideoBudget`. Continuous interaction therefore can hold a committed lower resolution indefinitely. Removing only the spatial veto does not safely coordinate these owners. | Add a separately admitted interactive recovery lane through the master gate. Preserve the cadence-trial veto and measured spatial proof. |
| Add a 900p rung | The attached script adds a constant and nominal bitrate branch, but leaves `nextRecoveryRung` selecting the native profile directly after 720. | Add a real, profile-bounded 720 -> 900 -> native recovery rung. Each step earns fresh proof from its own actual geometry. |
| Add encoder `KEY_LOW_LATENCY` | Android specifies this key **only for decoders**. It is not the encoder equivalent of `KEY_LATENCY`. | Keep it off the encoder. |
| Copy configured FPS into encoder `KEY_OPERATING_RATE` | Android already uses `KEY_FRAME_RATE` as the operating rate when realtime `KEY_PRIORITY=0` is present. This encoder already sets that priority. Merely copying the same value does not prove a DVFS or batching fix. A legacy bitrate adjuster can also configure 30 FPS independently of actual stream cadence. | Keep existing encoder configuration. |
| Shorten high-cadence settle timers | The current source-clock policy already selects source-compatible promotion rungs rather than requiring every historical numerical rung. The timers fence telemetry after operating-point changes. No phone trace proves that shorter timers improve delivered FPS. | Keep current timing and rollback. |
| Change local touch sample deduplication from 12 to 8 ms | `TOUCH_SAMPLE_INTERVAL_MS` belongs to local gesture-point filtering. The independent live drag sender uses `GestureStreamPacer`; changing this constant does not establish 120 Hz transmission. The current pacer already preserves event-clock phase. | Keep current sampling/pacing. |
| Shorten discrete tap hold from 80 to 48 ms | The tap is dispatched after controller release, and Android begins the injected gesture before its completion callback. Shorter hold is not evidence of the same reduction in finger-down-to-visible latency; target apps may sample presses differently. | Keep the existing tap duration until app/device tests justify a change. |
| Replace native bitrate budgets with fixed 4.2/5.2 Mbps numbers | Content, actual dimensions and cadence determine demand. No measurements calibrate those proposed constants for these phones. | Use existing measured RTP demand and projected next-rung cost. |

The attached script's interactive expression can override
`allowResolutionRecovery=false`; its added test explicitly expects this bypass.
That flag includes both the master freshness veto and the active cadence-trial
veto in the real host. A healthy queue must not override either. The script's
encoder text replacements also contain their own old anchors, so applying it
again can duplicate hints and the helper method. It is not used as an installer.

Android references:

- [MediaFormat.KEY_LOW_LATENCY](https://developer.android.com/reference/android/media/MediaFormat#KEY_LOW_LATENCY)
- [MediaFormat.KEY_FRAME_RATE](https://developer.android.com/reference/android/media/MediaFormat#KEY_FRAME_RATE)
- [MediaFormat.KEY_OPERATING_RATE](https://developer.android.com/reference/android/media/MediaFormat#KEY_OPERATING_RATE)
- [MediaFormat.KEY_LATENCY](https://developer.android.com/reference/android/media/MediaFormat#KEY_LATENCY)

## Resulting behavior

The master gate exposes `allowInteractiveResolutionRecovery` only after its
existing four clean glass windows, on a new actual presentation sample during
interaction. Repair, queue, playout, glass and ACK-to-swap pressure retain their
vetoes. The host additionally rejects all resolution growth during an active
cadence trial or an interval already owned by another actuator.

`MotionVideoBudget` still owns the actual resize. During interaction, it requires:

- A known hardware encoder, moving source supply, measured positive RTP bitrate,
  and sender dimensions matching the committed source geometry.
- Uncapped next-rung demand within the profile bitrate maximum, with at least
  1.60x bandwidth-estimate headroom.
- Both encode and decode service times, projected by the **next/current pixel
  area ratio**, below 35% of the active frame period; sender queue below 10 ms
  and the larger actual/target playout delay below 18 ms.
- Fresh actual presentation, bounded render gaps, delivery, loss and RTT, and
  five consecutive eligible recovery windows plus the existing settle/cooldown.

These are conservative admission thresholds, not empirically measured hardware
guarantees. Ordinary and interactive votes cannot be pooled across touch-down or
release. Missing sender evidence and component replacement discard transient
proof. No speculative warm-start prediction may become an upsize.

The 900-short-edge rung is a real source/output geometry change: a native
1080x2400 profile recovers 720x1600 -> 900x2000 -> 1080x2400. A profile below 900
is respected exactly. Fresh measured dimensions and new proof are required after
each commit. Spatial pressure retains the existing immediate relief path back
to 720 and, when necessary, the lower readable rungs with a 360 short-edge floor.

If an interactive upgrade is followed by committed spatial pressure relief
within the existing five-second settle period, that failed target is blocked
for the rest of the same interaction. Lower rungs can still recover. Release or
encoder replacement permits a fresh attempt. A later independent network dip
can recover during the same gesture. This avoids repeatedly paying for a failed
resize without turning a much later bandwidth dip into a permanent detail cap.

The primary RTP/capture/renderer path, input protocol, tap duration, encoder
configuration, FPS settle constants and release version are unchanged.

## Verification and limits

Validation results are recorded after running the checks below. Unit tests prove
admission, veto, recovery and rollback behavior; they do not measure phone FPS,
thermal behavior, vendor reconfiguration time or causal input-to-photon latency.
A MediaCodec size change can still hitch even when projected throughput fits.
Compare the baseline and changed APKs on the same two phones, including continuous
touch, weak networks, direct/TURN transport, codec changes and orientation changes
before claiming smoother gaming or guaranteed 720p/1080p.

Final validation used Temurin JDK 17, Gradle 9.6.0 and Android API 36:

```sh
gradle :app:testDebugUnitTest :app:lintDebug :app:lintRelease \
  :app:assembleDebug :app:assembleRelease
```

- 758 unit tests passed with zero failures, errors or skips, including 13 new
  regression methods and the gaming policy matrix. The matrix now uses the
  production master/cadence resolution-recovery admission flags.
- Debug and release lint completed with zero errors and 103 warnings each.
- Debug and unsigned release APK assembly completed successfully. No APK was
  installed on a phone or published as a signed release.
- `git diff --check` passed. A string-only round-trip of the supplied encoder
  patch confirmed one helper declaration after its first application and two
  after its second; the proposed installer was not applied to repository files.
