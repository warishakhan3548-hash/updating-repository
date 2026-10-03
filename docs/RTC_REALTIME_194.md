# Aaris Remote 1.9.4 — Real-time screen flow

## Goal

Make remote control feel like operating the phone locally: prioritize fresh pixels over nominal frame rate, preserve text geometry when possible, and keep motion cadence active for the animation/fling tail after a gesture ends.

## End-to-end path

`MediaProjection -> ScreenCaptureTrack -> WebRtcPeer video sender -> ICE direct/TURN relay -> controller WebRtcPeer -> EglRenderer/TextureView`

Cloudflare `aaris-remote-ice` is the control plane: pairing, signaling replay, hibernatable WebSockets and TURN credential minting. It does not proxy steady-state screen video frames, so frame-flow tuning belongs in the Android/WebRTC media path.

## 1.9.4 changes

### Data-plane motion authority

The host now treats a valid control command as the authoritative indication that visible remote motion is happening. This closes the dual-DataChannel ordering race where an unordered low-latency `GestureStream.CONTINUE` could arrive before the reliable `InteractionState(true)` hint.

Any valid tap, swipe, gesture stream, two-finger gesture, Back/Home/Recents or text command can immediately promote capture/encoder policy into interaction mode.

### Animation-tail preservation

`InteractionState(false)` is now only an early idle hint. It no longer cancels motion priority immediately. The host keeps its existing short interaction timeout, refreshed by actual commands, so fling, launcher and page-transition animation frames remain smooth after finger-up. Peer disconnect and control-channel closure still clear interaction priority immediately.

### Freshness-first cadence governor

The cadence governor still uses the stable ladder `60 -> 30 -> 24 -> 20 -> 15` and lets libwebrtc own bitrate/pacing/congestion control, but it now reacts to latency before the user sees a freeze:

- sender queue residence contributes directly to pressure;
- receiver jitter-buffer residence contributes directly to pressure;
- receiver drop ratio is measured over the current window;
- severe queue/jitter/loss pressure may downshift after one measured window;
- moderate pressure requires confirmation;
- recovery requires sustained low queue, low jitter, low loss and decoder/encoder headroom;
- resolution reduction remains a later fallback after cadence has already been reduced.

The intended behavior is not “force 60 FPS”. It is “deliver the freshest sustainable cadence without building a stale-frame queue”.

## Cloudflare production parity

During the 1.9.4 audit, the live `aaris-remote-ice` Worker script was verified byte-for-byte against the repository `cloudflare/core-worker.js`. No control-plane drift was present, so no placebo Worker deployment or placement change was made for the video-flow problem.

## Regression coverage

`VideoFeedbackTest` now covers:

- sustained sender queue delay triggering cadence reduction before a visible freeze;
- severe queue delay reacting in one measured health window;
- receiver jitter-buffer delay triggering pressure without requiring frame drops/freezes;
- existing recovery, legacy-controller and pipelined-hardware behavior.
