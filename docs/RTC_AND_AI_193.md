# v1.9.3: target-aware AI control and measured video cadence

## Problem and behavior

The supplied recording shows a connected AI observing successfully while Home,
launcher taps and swipes fail with SCREEN_CHANGING/STALE_SCREEN. Previously any
Accessibility event revoked the whole-screen ticket, including events from
streaming chat or overlay relocation. The queue repeated that same check.

AI now issues a coherent ticket even during ordinary animation, compares fresh
pixels and semantics at the requested target/path, and rechecks the window/target
inside the queue. Global navigation does not require a static picture. Geometry,
privacy masks, focused-field selection, single-use tickets, action deduplication,
local STOP, lock checks and the shared command gate remain enforced. These checks
reduce stale-target errors; they cannot prove a model chose the correct action.

## Live video

- Sample RTP stats every second and calculate interval deltas for codec time,
  jitter-buffer residence, drops, freezes, bitrate and sender queue delay. Lifetime
  averages remain labeled diagnostics; they no longer hide a recent slow period.
- The controller sends a 46-byte bounded feedback packet over the existing
  encrypted control channel. The host checks lease, display generation and
  increasing sequence, consumes each report once and expires it after 3 seconds.
  Unknown packet types remain ignored by older peers; input sequence numbers are
  independent of feedback sequence numbers.
- Repeated encoder/decoder pressure, drops or congestion steps the capture FPS
  ceiling through supported 60/30/24/20/15 limits, no faster than every 3 seconds.
  The current interaction/idle target is also respected. This reduces pipeline
  workload before the slower resolution governor sacrifices readable text.
- Cadence may recover after sustained measured headroom and at least 12 seconds.
  Older controllers recover more conservatively using measured sender health.
  Quiet screens and missing stats alone cannot justify a quality change.
- Existing liveness/recovery and resolution checks retain their 3-second timing.
  GCC still owns bitrate/pacing. Display geometry, codec negotiation, JPEG/delta
  reconstruction and the unobstructed viewer are unchanged in this release.

This does not claim 60 fps on every phone, zero latency, or a measured reduction
on the user's hardware. Validate native text, scrolling, rotation and network
changes on two real phones. Compare recent encode/decode/jitter metrics, dropped
frames, freezes and p95 input-to-photon under the same conditions. Prefer the new
build on both phones to enable receiver feedback.

## Verification

Regression scenarios cover continuous animation with tap/long press/swipe/Home,
actual target movement/color changes, rotation, focus/selection, privacy changes,
STOP/disconnect, ticket expiry/reuse, and the dispatch deadline. The engine tests
fake only JPEG encoding (JVM YuvImage lacks it), not pixel/target validation.
Video tests cover cumulative-counter deltas/resets, malformed packets, foreign
leases, replay/stale feedback, slow receivers, isolated spikes, static screens,
and gradual recovery with both new and old controllers. MCP tests verify animated
tickets, fresh rejection images and durable action deduplication.

## Engineering references

- W3C WebRTC statistics: https://www.w3.org/TR/webrtc-stats/ — codec/jitter/send-delay
  counters are cumulative; current averages require interval differences.
- Meta RTC engineering: https://engineering.fb.com/2026/06/22/video-engineering/adopting-av1-for-real-time-communication-rtc-meta/
  — sender and receiver compute limits matter as well as network bitrate. This
  release applies that measurement principle; it does not transplant Meta's
  proprietary codec or assume AV1 is faster on every Android device.

The pinned WebRTC Java SDK exposes temporal-layer parameters but no public
VideoTrack content-hint or receiver jitter-delay setter. Automatic AV1/VP9 and
new temporal modes remain subject to device/runtime validation, rather than
being enabled without an encode/decode benchmark.
