# Realtime encoder mode (1.9.15, build 103)

The new device recording still shows pauses after 1.9.14. It does not expose a
complete synchronized RTP trace, so it cannot establish a single device-specific
bottleneck. Review found two concrete gaps in the previous policy:

- The Android VideoSource was created in screencast mode. Upstream
  `ConfigureVideoEncoderSettings` and `CreateVideoEncoderConfig` disable automatic
  resizing / quality scaling for this mode independently of the sender's explicit
  degradation preference. Setting MAINTAIN_FRAMERATE alone did not enable that path.
- The 1.9.14 cadence floor persisted whenever another pixel reduction was possible.
  Moderate receiver jitter could trigger cadence pressure without triggering pixel
  pressure, leaving both governors unable to relieve it.

The source now selects realtime-video encoder mode once at construction. Android
screen capture still uses the same ScreenCapturerAndroid, MediaProjection consent,
foreground service, and stable virtual display. There is no camera capture and no
mid-session encoder-mode toggle. Sender policy permits native motion adaptation
from the initial transceiver configuration, including before motion is detected.
Static detail can recover through the pixel budget rather than a competing switch
back to MAINTAIN_RESOLUTION.

The host cadence ceiling is 30 FPS. Successful recovery no longer increases it to
45 or 60 FPS and reintroduces load. A pixel change temporarily protects cadence
for three seconds; after that the freshness governor may respond to pressure.
Unchanged VideoSource formats and unchanged RTP parameters are no longer reapplied.
Startup diagnostics identify the exact app build and selected encoder mode.

Native behavior reference:
https://webrtc.googlesource.com/src/+/refs/heads/main/media/engine/webrtc_video_engine.cc

Verification covers the moderate-jitter deadlock, bounded cadence recovery, initial
and idle sender policy, and existing capture/motion regressions. Full Android tests,
lint and APK assembly run in CI. Native device performance and physical two-phone
motion-to-display latency still require measurement on the affected phones.
