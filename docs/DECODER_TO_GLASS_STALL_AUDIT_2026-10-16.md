# Decoder-arrival-aware controller glass feedback (16 October 2026)

Repository: `warishakhan3548-hash/updating-repository`
Base: `996a5f641cc303dfecf76e8b907bf9ed20ef1446`
Change surface: `PresentationCadenceTracker`, the existing `InlineRemoteControllerView` decoder timestamp, and focused JVM tests.

## Execution / state map

```text
Host consent -> ScreenShareService -> ScreenCaptureTrack -> VideoSource
 -> hardware-first encoder -> WebRtcPeer RTP/GCC/ICE/TURN
 -> ControllerWebRtcSession -> native jitter/decode -> VideoTrack
 -> InlineRemoteControllerView.renderSink
      -> monotonic decoded-at timestamp (existing watchdog field)
      -> decoded callback sequence -> EglRenderer.onFrame (latest pending)
      -> EGL swap listener -> PresentationCadenceTracker
          -> authenticated PresentationFeedback -> ReceiverVideoFeedback
          -> HostWebRtcSession -> existing Photon/Cadence/Spatial governors
          -> next source/capture and encoder operating point
Controller touch -> RemoteViewportMapper -> GestureStreamPacer
 -> control DataChannel -> host command authorization -> Accessibility -> pixels
```

## Exact blind spot and correction

A previous decoder-aware patch correctly stopped blaming EGL for a 2.5-second static-screen gap if at most one new decoded callback occurred. But *one callback* is ambiguous: it could arrive just before the eventual swap (true source silence), or it could arrive seconds before that swap (EGL/presentation delay). The previous count-only classifier suppressed **both**.

The decoder callback already reads `SystemClock.elapsedRealtime()` for its watchdog. Stamp that existing value just before publishing the decoded callback sequence and handing its texture to EGL, then supply the timestamp with the sequence at actual swap. For a >=750 ms glass interval with precisely one new callback, preserve the static-screen exemption **unless** that decoded frame was already available >=200 ms before the eventual EGL swap. A valid early arrival thus preserves real presentation-gap feedback; a just-arrived frame still reanchors instead of inventing renderer congestion. Missing/invalid times retain existing count-only behavior. Zero-callback gaps and two-or-more-callback gaps preserve their current treatment.

No additional queue, frame copy, bitmap allocation, codec override, WebRTC pacing loop, retransmission or RTP parameter is introduced. No change to access control, pairing, input protocol, or UI layout.

## Boundaries and acceptance

This is a classifier correction, **not** evidence that physical micro-stutter has disappeared. The latest decoded-arrival timestamp is only discriminating for a single callback; it cannot locate the first decoded arrival in a multi-callback burst and cannot alone isolate GPU stall from a Surface outage. Physical testing must still distinguish those cases using actual decoder and EGL events.

Run `gradle :app:testDebugUnitTest :app:lintDebug :app:lintRelease` and debug/release assembly in CI. Compare same two devices, codecs and direct Wi-Fi / mobile+TURN paths with 10-minute sequences of static screen -> motion, one decoded frame held before EGL swap, background/foreground and rotation recovery, fast scrolling and a demanding game. Record capture/encoded/decoded/EGL-presented FPS, p95/p99/max active-motion glass gaps, codec service time, jitter residence, frame size/bitrate, thermal state, and command-to-changed-pixel latency. Reject if real active-motion render gaps worsen. 720p+ and 60fps cannot be guaranteed on an under-capacity link or a constrained device.
