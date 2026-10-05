# Sustained sessions and a lighter capture engine (1.9.12)

## Evidence and scope

The supplied device recording shows software VP8 (`libvpx`) encoding
1080×2400 frames in about 90 ms, with a recent output near 3 fps, followed by
primary-video recovery and H264 renegotiation. This confirms an encoder cost
problem. Returning to the launcher does not by itself establish an Android
memory kill; no device logcat or process-exit record was supplied.

The deployed Cloudflare session state machine has no LIVE deadline. A signaling
socket closing does not end an already-LIVE session. The previous Android host
did end screen sharing only five seconds after a control-channel interruption,
and an expired 30-second input lease immediately destroyed the media session.

## Execution and UI map

`MainActivity` attaches the viewer and starts foreground services.
`ControllerConnectionService` owns the controller peer independently of that
Activity. `ScreenShareService` owns the consented projection, `ScreenCaptureTrack`
and `HostWebRtcSession`. Screen frames go to RTP; reliable `control-v1` carries
handshakes and heartbeats, and `control-live-v1` carries fresh motion packets.
Cloudflare performs pairing, approval, state observation and SDP/ICE signaling.

A temporary route/control interruption now preserves capture for one fixed
45-second recovery budget. Expired input remains unauthorized. A recovered,
authenticated peer receives a new lease through HELLO; replayed old-lease input
is still rejected. Repeated disconnect callbacks cannot extend the deadline.
User STOP, projection withdrawal and Accessibility loss still terminate sharing.

## Capture changes

| Path | Previous budget | New budget |
| --- | --- | --- |
| STANDARD | 2400 long side, 45 fps / 60 motion, 10 Mbps ceiling | 1800, 30 / 45, 4.5 Mbps |
| HIGH | 2560 long side, 60 fps, 12 Mbps ceiling | 1920, 30 / 45, 6 Mbps |
| Known software encoder | Could recover to large RAM-selected tier | At most BALANCED: 1200, 24 / 30 |
| AI-only projection | STANDARD except low RAM forced to BALANCED; native video source and peer factory | BALANCED, or LOW on low RAM; snapshot sinks without native video source, track or peer/codec factory |

Measured encoding time above the frame budget reduces pixels even when vendor
stats omit `qualityLimitationReason=cpu`. Network-only pressure keeps the existing
cadence-first hysteresis. Hardware recovery can gradually restore the device's
bounded maximum. Logical display coordinates remain unchanged for touch mapping.
The virtual display is not repeatedly resized on network fluctuations.

AI still captures a GPU surface for current-screen observations. The Android
screen capturer does not enforce the requested FPS at that surface, so an 8 fps
setting must not be described as an 8 fps GPU capture guarantee. Image conversion
and uploads were already demand-driven and remain so. This change removes the
unused native frame-forwarding path and reduces projection pixels.

Controller heartbeats use one owned scheduler instead of the UI Looper. Channel
closure cannot permanently cancel its recurring task. A sticky controller service
can restore its persisted session/token; explicit STOP clears that owner. Crash
reporting no longer closes an otherwise recoverable controller session. Android
11+ system exit records distinguish reported low memory, native crashes and ANRs;
signal termination is reported without guessing its cause.

## Validation

Regression tests cover bounded handoff recovery, repeated flaps, old-lease
rejection, software quality ceilings, measured encoding pressure, hardware
recovery and display/input geometry. CI runs the complete Android unit suite,
debug/release lint and both assembly variants, plus existing Cloudflare tests.

`python cloudflare/soak-session.py --seconds 600` creates a disposable production
session across both public origins and two actual virtual WebRTC peers. It
decodes moving video, exchanges reliable heartbeats and unordered motion,
disconnects/reconnects signaling, and renegotiates VP8 to H264. It checks LIVE
state on both routes every 15 seconds, requires at least 18 decoded fps on
average, bounds video gaps, and closes its synthetic session in `finally`.
The associated Actions workflow retains the results.

This is live production signaling with local ICE/RTP between virtual peers.
TURN credentials are issued and checked, but relay media, mobile NAT, Android
MediaCodec, battery/thermal behavior and physical-device rendering are not
covered. The local workspace denied UDP socket creation, so media validation
runs on the CI machine.

Physical-device acceptance still requires a ten-minute video/swipe session,
backgrounding each app, a 10–20-second Wi-Fi/mobile handoff, screen rotation,
AI observations while switching apps, and an explicit STOP/permission-withdrawal
check. If Android revokes MediaProjection or kills the host process, fresh
screen-share consent is required; no silent host restart is attempted.
