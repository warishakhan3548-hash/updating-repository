# Idle-safe realtime motion cadence (1.9.17, build 105)

## Why

The previous 1.9.16 host could retain a 24/20/15 FPS congestion downshift
during long static screens. Cadence recovery needs multiple encoded frames,
but Android MediaProjection emits few or none when nothing moves. When new
remote interaction or passive movie/animation motion began, the low cap
could carry into the first seconds of real motion despite a recovered path.

Conversely, when sender output and producer activity were both effectively
quiet, stale RTT/loss statistics could push cadence lower even though no
new video frames were waiting to be delivered.

## Change

- Preserve WebRTC native congestion control and the existing 30 FPS ceiling.
- Ignore low-activity encoder cadence changes **only** when the producer is
  measured quiet (<2.5 FPS) and the sender has at most three frames in a
  sampled window; all unmeasured/active paths retain the original safety.
- On a real transition to motion, consider a **single** bounded cadence
  recovery rung, at most 30 FPS, when all of the following are measured:
  - Quiet producer and quiet encoder in the previous stats window.
  - A fresh sample (<=2.5 seconds old).
  - No CPU/bandwidth limitation; RTT <=300 ms; loss <2.5%.
  - No measured slow send queue or excessive per-frame encoding.
  - At least 8 seconds since the last overload or cadence adjustment.
- Never repeatedly reapply a stale idle sample. The first gesture or native
  source-motion pulse consumes it; later motion must gather new evidence.
- No new native thread, secondary encoder, image readback, jitter buffer,
  custom RTP pacing, signaling protocol, or accessibility changes.
- A probe is **not** a guaranteed 30 FPS stream: on renewed pressure the
  existing cadence/pixel governors remain authoritative.

## Validation

Regression tests cover quiescent-source protection, active congestion
protection, one-rung recovery, cooldown, stale feedback, codec/RTT guards,
and no forced recovery without evidence. PR CI runs Android unit tests,
debug/release lint, debug/release assembly, MCP protocol checks and the
Cloudflare smoke workflow.

## Remaining performance questions

The observed libvpx implementation may still dominate CPU and/or frame
residence on the affected device. Codec switching must be driven by
mutually supported hardware capabilities and synchronized two-phone traces;
forcing a codec or increasing the FPS target blindly can worsen stutter.
Also measure encoder, network, decoder, and actual EGL-present cadence on
the two physical phones before asserting improved end-to-end latency.

Rollback base: 1.9.16 build 104 / commit
2f8cd65b627141f79e69d14cbc1b09685f4f51e3.
