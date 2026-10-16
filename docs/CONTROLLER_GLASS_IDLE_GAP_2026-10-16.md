# Controller glass cadence: decoder-aware idle gap fencing

Repository: `warishakhan3548-hash/updating-repository`
Baseline: `cd9dfd1539bcf8c669527e6078948564f18a1b1f`

## Source and state map

```text
ControllerConnectionService
  -> ControllerWebRtcSession -> WebRtcPeer -> decoded remote VideoTrack
  -> InlineRemoteControllerView.renderSink
       [decoder callback count, one atomic increment]
       -> EglRenderer.onFrame (native latest-frame-wins EGL queue)
       -> EGL surface buffer swap -> installPresentationListener
            -> PresentationCadenceTracker.onPresented(swapMs, decodedCount)
            -> PresentationFeedback (existing telemetry DataChannel)
            -> ReceiverVideoFeedback.consume (host policy lane)
            -> PhotonFreshnessGovernor / VideoCadenceGovernor / MotionVideoBudget
            -> HostWebRtcSession.applyVideoPolicy
                 -> VideoSource.adaptOutputFormat + RTP sender envelope
                 -> host's next captured and encoded frame
```

The existing surface lifecycle fence/reset continues to own presentation epochs. MediaProjection, RTP pacing, jitter buffer, decoder, Cloudflare pairing, fallback recovery and authenticated remote input are unchanged.

## Verified defect and surgical correction

Before this change, the tracker used only successive EGL swap timestamps. A host phone showing an unchanged page may legitimately produce very few new decoded frames. If an EGL swap occurred at t=1,000 ms and the next real swap appeared at t=3,500 ms, the old tracker reported **one swap in a 2,500 ms interval** with a 2,500 ms max render gap. This looks exactly like severe renderer congestion to the host video governor even if no decoder frame was available to render during the interval. The next motion burst could then be downshifted on contaminated presentation evidence.

Instead, each decoded frame increments one atomic sequence before being submitted to EglRenderer. When a **>=750 ms** glass gap had at most one additional decoded callback, the next swap re-anchors the cadence window. That gap is producer/network silence, **not proven EGL backlog**. The first fresh swap still confirms display liveness. A real EGL stall with two or more decoded callbacks during the gap continues to emit its full max-gap/fps-pressure report, and gaps below 750 ms keep their existing accounting. With missing decoder evidence, the original timestamp-only behavior remains unchanged.

The single sequence is a cross-thread *measurement*, not a frame queue, media pacing loop or on-screen interpolation layer. Reset clears both glass and decoder evidence. It is deliberately a conservative classifier, not a claim that source/transport silence is healthy: encoder, RTP, decoder freeze and connection watchdog metrics remain responsible for those separate failures.

## Scope, tests and acceptance

New `DecoderAwarePresentationCadenceTest` covers quiet 2.5-second idle-to-motion resumption, continued decoding with a 2-second EGL stall, real 500 ms sparse cadence, Surface reset, and absent decoder evidence. Existing presentation, input, fallback, codec and Android lifecycle suites are unchanged.

Run `gradle :app:testDebugUnitTest :app:lintDebug :app:lintRelease` in CI. Real two-phone verification is still required before asserting measurable improvement: static page -> start a fast scroll after 2-5 seconds; fullscreen 60 fps game; artificially induced EGL stalls; Wi-Fi versus TURN and low bandwidth; portrait/landscape and Surface recreation. Compare decoded arrivals, actual EGL swaps, p95/max swap-gap during active motion, dropped frames, resolution rungs and command-to-changed-pixel latency. No software-only check proves native-feeling latency or a fixed 720p/60 fps guarantee on every network.
