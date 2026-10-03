# Aaris Remote 1.9.7 — primary-frame priority + precise AI drag

## Live screen path

The media path remains WebRTC-first: `MediaProjection -> ScreenCaptureTrack -> WebRTC video sender -> direct/TURN ICE -> controller EGL renderer`. Cloudflare Workers remain signaling/authentication/TURN-credential control plane and do not proxy steady-state screen video.

`ScreenCaptureTrack` now admits each capturer callback into the primary WebRTC `VideoSource` before invoking auxiliary snapshot sinks. Fallback recovery and AI snapshot consumers still receive every capturer callback, including forced static-screen samples, but auxiliary conversion/retention work can no longer sit ahead of the current latency-critical RTP sample on the capture callback.

This is a priority change, not an FPS inflation hack. Existing presentation-aware cadence, receiver-health feedback, bitrate policy, interaction mode, and adaptive capture tiers remain authoritative.

## Precise AI drag

`phone_action` adds `drag`, a single action containing 2–24 normalized points plus the existing `durationMs` range. The Android side maps it onto the already production-tested `ControlPacket.GesturePath` / `GesturePathCommand` executor used by human controller paths. The AI therefore gains curved, slight, slow, and fast drags without introducing a second privileged input engine.

A drag is still bound to exactly one fresh observation ticket. Before execution, the full polyline corridor is revalidated against fresh pixels and the Accessibility snapshot. Sensitive-input blocking, window identity checks, generation checks, one-use observation tickets, and post-action observation all remain unchanged.

## Idempotency

MCP action digests now canonicalize nested objects recursively. This matters for drag because point objects may arrive with JSON keys in a different order on an otherwise identical transport retry. Array order is intentionally preserved because point order defines the gesture.

## Regression gates

- MCP validation covers bounded drag paths, malformed paths, and nested canonicalization.
- Android unit tests cover drag-to-`GesturePathCommand` pixel mapping, duration preservation, invalid coordinates, and curved corridor geometry.
- Existing MCP protocol tests continue to cover durable action admission, uncertain outcomes, authentication, STOP semantics, privacy-safe result storage, and replay behavior.
- Pull-request CI must pass Android unit tests, debug/release lint, debug/release APK builds, MCP protocol tests, and the live Cloudflare control-plane smoke test before merge.
