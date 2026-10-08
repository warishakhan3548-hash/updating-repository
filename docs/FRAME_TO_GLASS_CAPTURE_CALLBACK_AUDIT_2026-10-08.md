# Frame-to-glass capture-callback isolation audit (2026-10-08)

## Source and execution map
- Controller gesture: `InlineRemoteControllerView` → `ControllerWebRtcSession` → ordered or freshness-oriented WebRTC DataChannel → `HostWebRtcSession` → Accessibility action → Android compositor.
- Primary host pixels: Android compositor → `MediaProjection` → `ScreenCapturerAndroid` → `SurfaceTextureHelper` callback → `ScreenCaptureTrack` → `VideoSource.capturerObserver` → SEND_ONLY RTP → native H.264/VP8 MediaCodec/encoder → native congestion-control pacer → ICE direct UDP/TURN → controller RTP reorder, NACK, jitter timing → native decode → `VideoTrack` → `InlineRemoteControllerView`/`EglRenderer` → Surface.
- Browser receiver: native RTP → browser `RTCRtpReceiver` and `<video>` compositor; its application buffer recommendation is `cloudflare/receiver-playout.js`. Browser/AI JPEG fallback is **not** the primary WebRTC media stream.
- Closed loop: sender `getStats()` → `VideoHealthWindowTracker` → `HostWebRtcSession` + viewer `ReceiverVideoFeedback` → `MotionVideoBudget`/ `VideoCadenceGovernor`/ `PhotonFreshnessGovernor` → `ScreenCaptureTrack.adaptOutputFormat` and `WebRtcPeer.updateInteractiveVideoPolicy`. EGL proof-of-glass arrives on a separate bounded telemetry lane.

## Specific source-thread defect addressed
`ScreenCaptureTrack.onFrameCaptured` submits each original texture frame to native WebRTC video *before* its auxiliary `snapshotSinks` fan-out. That protects the current frame, but a slow auxiliary sink still occupies the **same** `SurfaceTextureHelper` capture callback thread, delaying delivery of the **next** frame.

The AI link snapshot sink `AiSnapshotProvider` used to perform both `frame.buffer.toI420()` (GPU → owned CPU copy) and a full `FrameImageEncoder.toNv21()` row/interleaving loop synchronously inside that callback. A burst of AI screen observations could consume part of the 33.3-ms budget at 30 FPS (16.7 ms at 60 FPS) and cause visible source jitter. This is a confirmed synchronous hotspot, **not measured proof** it caused every reported 2–6 FPS event.

### Surgical change
- Keep the necessary `toI420()` handoff *inside* the callback. The SurfaceTexture producer can have only one texture frame in flight; retaining the original `VideoFrame` for background conversion may starve future capture frames.
- Capture the frame rotation as a primitive, then submit only the independent `VideoFrame.I420Buffer` to a single low-priority CPU conversion worker for `toNv21()`.
- Reject overlapping conversion with `CAPTURE_BUSY`; `conversionInFlight` ensures at most one owned CPU frame is outstanding. Never queue old frames, modify native RTP pacing or run an extra MediaProjection.
- Worker `finally` releases the owned I420 exactly once on success/failure. Shutdown **drains** ownership; never cancel tasks that hold buffers without cleanup. `close()` cancels pending requests.
- Primary phone-to-phone video without AI screenshot work is unchanged. Ordinary WebRTC latency/congestion and the fallback JPEG sink are unchanged.

## Why simply forcing 60 FPS or adding a large buffer is not a repair
At 30 unique frames/sec each frame period is 33.3 ms. If native capture produces 6 unique FPS, a decoder or a 500-ms queue cannot invent the missing 24 distinct frames. Software VP8 codec overload, MediaCodec restarts, sender residence, network scarcity, jitter delay, decode and EGL stalls must be distinguished before changing cadence.

Max sustainable cadence is constrained by source frame supply, encode throughput, effective network delivery and decoder/display throughput. Native WebRTC's GCC/TWCC, frame dropping and NACK recovery remain owners of transport behavior. A small adaptive jitter reservoir may smooth *arrival variance* but increases control-to-photon delay; 500 ms must not become a constant penalty.

## Device acceptance/measurement plan (not yet run)
Use **two Android phones**, the same 10-minute moving-screen/touch sequence and fixed comparable network conditions on before/after APKs:
1. Check complete 10-minute session and no permissions/background/Home-screen regression.
2. Record host original producer FPS, encoded FPS, encode service ms, send queue ms, codec implementation, outgoing bitrate, quality limitation, RTT, packet loss and ICE route.
3. Record controller received/decoded FPS, decode service ms, playout residence, EGL actual presented FPS, p95/p99 inter-swap gaps and command ACK-to-next-actual-swap proxy.
4. Run stable Wi-Fi/direct ICE, poor bandwidth/loss and a mobile/TURN route separately. Repeat with AI live observations active; compare capture callback jitter with AI snapshots disabled/enabled.
5. Fail if main screen freezes, capture source < requested cadence without an explained hardware/network limit, repeated codec resets, increasing send residence or added touch-to-photon latency.
6. Do not claim Google-Meet-level smoothness, zero lag, or a resolved 2-FPS root cause on the basis of software CI or simulated browsers.

Useful starting point: `docs/FRAME_SUPPLY_AND_PRESENTATION_AUDIT_2026-10-08.md`, `docs/PHONE_TO_PHONE_FRAME_JOURNEY_2026-10-08.md`.
