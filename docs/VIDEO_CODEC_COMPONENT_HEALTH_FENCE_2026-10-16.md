# Codec-component health-window fencing (16 October 2026)

Repository: `warishakhan3548-hash/updating-repository`.
Baseline: `6352cfa48d6a6a6d59da64529cc2a3ccd986b83e`.
Scope: one native WebRTC telemetry ownership boundary; no Android permissions,
UI layout, signaling, transport, codec preference or RTP frame queues are changed.

## Dependency tree: pixels, decisions, and controls

```text
Host permission + pairing -> ScreenShareService
  -> HostWebRtcSession
    -> ScreenCaptureTrack
      -> MediaProjection / ScreenCapturerAndroid / SurfaceTextureHelper
      -> VideoSource / VideoTrack -> hardware-first encoder
    -> WebRtcPeer -> congestion control / RTP pacing -> direct ICE or TURN
      -> ControllerWebRtcSession / WebRtcPeer
        -> native packet reordering, jitter timing and decoder
        -> InlineRemoteControllerView.renderSink
          -> EglRenderer (one replaceable pending frame)
          -> SurfaceView / Android compositor -> visible remote pixels
          -> PresentationCadenceTracker / receiver decoder stats
          -> ReceiverVideoFeedback -> host's existing policy lane
    -> WebRtcPeer.getStats -> VideoHealthSnapshot
      -> VideoHealthWindowTracker [THE SURGICAL BOUNDARY]
      -> HostWebRtcSession.onVideoHealth
        -> MotionVideoBudget (spatial rungs)
        -> VideoCadenceGovernor (temporal rungs)
        -> PhotonFreshnessGovernor (proof of timely presentation)
        -> CaptureQualityGovernor (longer-term device/detail pressure)
        -> applyVideoPolicy -> VideoSource.adaptOutputFormat + RTP max ceilings

Controller touch -> RemoteViewportMapper / GestureStreamPacer
  -> lease-/generation-bound ControlProtocol messages via SCTP DataChannels
  -> HostWebRtcSession -> authorization/replay/geometry gate
  -> AssistAccessibilityService -> changed host pixels
```

Cloudflare pairing, TURN authorization, browser/AI agent and fallback JPEG/delta
recovery retain their existing owners. Primary video is not routed through JPEG,
bitmap composition or an application-managed decoded-frame reservoir.

## State / visual intersection

```text
Controller enters pairing code -> host approval and MediaProjection consent
  -> negotiated remote VideoTrack -> decoded frame -> actual EGL swap
  -> controller sees friend's screen
  -> controller drag/tap -> authorization -> host Accessibility gesture
  -> new host frame -> encoder -> RTP -> decoder -> EGL -> updated pixels
  -> sender getStats() reports cumulative frames, time, packets and component
  -> tracker emits completed interval ONLY for one coherent operating point
  -> quality / cadence policy may update pixel and FPS ceilings
```

There was a mismatch: `VideoCadenceGovernor.onSenderEvidence()` already
recognizes concrete encoder changes, but `VideoHealthWindowTracker.sample()`
previously seeded only by stream ID, direction and MIME. A vendor/codec
reinitialization can preserve these identifiers while replacing the actual
`encoderImplementation` / `decoderImplementation`. Subtracting total
frame/codec/packet counters across that boundary can manufacture a normal or
bad measurement unrelated to any single codec. That incorrect result can be
fed into both cadence and resolution controllers and cause avoidable
promotion/downshift oscillation or obscure a genuine stall.

## Corrective behavior

- Normalize nonempty implementation labels (trim + case-fold) and remember the
  last concrete component across temporarily missing metadata.
- When the same RTP stream and MIME reports a different concrete implementation,
  seed a **new** cumulative baseline and emit **no completed interval** for the
  replacement sample. Require a fresh 500–6000 ms window before adaptation.
- Preserve the existing timestamp-gap, stream/MIME replacement and counter-reset
  paths; keep partial (<500 ms) probes from erasing a valid baseline.
- This affects only statistics admission. It does not add another adaptive
  controller, frame-copy worker, decoded-frame buffer or codec override.

## Regression and physical acceptance gates

`VideoHealthComponentBoundaryTest` covers sender and receiver codec replacement,
intermittently absent/blank implementation strings, case-insensitive identity,
early 120 ms probes, stream replacement and >6 s stats discontinuity. Run
`gradle :app:testDebugUnitTest :app:lintDebug :app:lintRelease` and relevant
Android assembly jobs. These checks must complete before merging.

A real two-phone A/B test remains required. Compare unchanged and patched
builds on identical phones under Wi-Fi and mobile/TURN, with a 60 Hz moving
screen and rotation/codec recovery. Record 10-minute source/encoded/decoded/EGL
presented FPS, pixel dimensions, p95/p99/max active-motion swap gaps, freezes,
encode/decode service time, RTP send queue, jitter residence, loss/RTT and
thermal state. Reject an upgrade if it raises render gap or interaction delay.
A test pass does not guarantee 1080p/60 FPS or local-device gameplay: weak
links, thermal throttling and non-live independent multi-touch are separate
limits.
