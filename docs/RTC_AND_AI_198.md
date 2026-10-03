# Aaris Remote 1.9.8 — smoother ambient motion + stronger AI hands

## Goal

Reduce the gap between the host phone's visible motion and the controller's rendered motion without replacing the existing freshness-first WebRTC design. Extend AI control with one additional human-like primitive while preserving the same authorization, stale-screen validation and Android Accessibility execution path.

## End-to-end architecture preserved

Human remote screen/control remains:

`MediaProjection -> ScreenCaptureTrack -> WebRTC RTP -> ICE direct/TURN -> controller EglRenderer`

Controller input remains:

`controller touch -> reliable/live DataChannel -> HostWebRtcSession -> CommandGate -> AssistAccessibilityService`

AI input remains:

`Cloudflare MCP -> persistent device socket -> AiObservationEngine -> AiActionTranslator -> same RemoteCommand/CommandGate/Accessibility path`

Cloudflare `aaris-remote-ice` remains signaling/TURN control plane. It does not proxy steady-state screen pixels, so no placebo video-proxy change was made there.

## 1. Capable phones keep smooth motion even between touches

Previously STANDARD and HIGH tiers returned to a 30 fps source ceiling whenever the remote finger was no longer considered active. That is efficient for static UI but it also caps continuously animated content such as games, video, progress animations and long inertial motion even when the encoder/network/receiver can sustain more.

1.9.8 changes only the capable tiers:

- LOW remains 15 fps idle / 20 fps interaction.
- BALANCED remains 24 fps idle / 30 fps interaction.
- STANDARD (normal 4 GB-class path) becomes 45 fps ambient / 60 fps interaction.
- HIGH (>=6 GB class) becomes 60 fps ambient / 60 fps interaction.

These values are ceilings, not forced send rates. `VideoCadenceGovernor`, WebRTC congestion control and the existing capture quality governor still reduce cadence or quality when sender queue, jitter, loss, CPU or receiver presentation pressure is detected.

## 2. Recovery transport can no longer retain the capture producer in its worker queue

The fallback JPEG/delta lane is active only when primary RTP is black/stalled. Before 1.9.8 it retained the incoming `VideoFrame` and handed that retained SurfaceTexture-backed frame to a background worker. The worker released the producer before JPEG/network work, but scheduler delay before the worker began could still keep the capture texture alive across callbacks.

That is especially undesirable during recovery because fallback work must never make primary RTP recovery harder.

1.9.8 replaces `RetainedFrameCopy` with `CpuFrameCopy`:

1. Primary RTP still receives the frame first in `ScreenCaptureTrack`.
2. If fallback accepts that sample, the bounded GPU-to-I420 ownership transfer is completed while the capture callback owns the source frame.
3. Any temporary scaled producer buffer is released before the callback returns.
4. The background worker receives only the independently-owned I420 buffer.
5. JPEG/delta analysis, compression and DataChannel sending can therefore never retain the capture SurfaceTexture producer.

The fallback lane still keeps its existing one-frame `encoding` gate and adaptive cadence, so this change does not introduce an unbounded CPU queue.

## 3. AI receives atomic two-finger control

The Android control protocol and human controller already supported simultaneous two-finger gestures, but the MCP AI tool could not request them. 1.9.8 exposes that existing primitive instead of creating a second privileged input engine.

New AI action:

`two_finger`

Coordinates are normalized over the full upright display:

- first finger: `x`, `y` -> `toX`, `toY`
- second finger: `secondX`, `secondY` -> `secondToX`, `secondToY`
- shared `durationMs`: 80..1500 ms

A finger can remain pressed in place by using the same start/end coordinate. This supports gestures such as pinch/zoom, two-finger scrolling, or hold+move controls while still being exactly one admitted AI action.

## 4. Multi-touch keeps fresh-screen validation

`AiActionScope` now models multiple independent paths. Both touch corridors are included in visual/semantic freshness checks. The space between two fingers is not treated as part of the action target.

The action still fails closed on stale/changed targets, sensitive input, lock state, geometry changes, STOP, foreground changes and authorization changes. Execution still goes through `ControlPacket.TwoFinger -> TwoFingerCommand -> AssistAccessibilityService`.

## Regression coverage

Added/updated JVM tests cover:

- STANDARD 45 fps ambient / 60 fps interaction and HIGH 60/60 while LOW/BALANCED remain constrained;
- CPU fallback copies not taking an additional producer-texture reference and idempotent CPU release;
- AI two-finger translation into the existing `TwoFingerCommand` pixel mapping;
- multi-path scope covering each finger corridor without treating the space between them as touched.

Existing CI still runs MCP protocol tests plus Android unit tests, debug/release lint, and debug/release APK assembly. Production Cloudflare workers should only be updated after the Android and MCP changes are validated together, so an older APK is never advertised an unsupported action.
