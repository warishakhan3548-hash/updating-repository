# Motion-first screen video (1.9.14, build 102)

The previous policy reduced capture cadence before permitting resolution relief,
then waited six seconds after the cadence change. Its resolution pressure budget
also followed the reduced frame rate. Motion could therefore remain choppy while
the pipeline appeared sustainable at a low FPS. Passive motion was inferred only
after encoding, so an encoder starting at 2 FPS could fail to activate it.

The motion path now counts fresh producer timestamps before RTP adaptation and
uses a 720 / 540 / 360 short-edge resolution budget. Forced static snapshots do
not count as new source activity. The existing MAINTAIN_FRAMERATE sender policy
also covers source motion when encoded cadence collapses.

Sustained encoding, pacing, decode, or presentation pressure lowers resolution;
severe sender queue/encode pressure can act after one window. A measured software
encoder starts with a 540 short-edge budget. Resolution changes have a three-second
settling interval; upgrades require twelve healthy windows at the motion target.
Missing telemetry and a healthy RTT at 15 FPS cannot promote resolution. Static
content regains the original detail after an eight-second idle hold.

Cadence keeps a target of up to 30 FPS while pixel relief remains available. If
360 pixels on the short edge is still too expensive after settling, or severe
transport loss occurs, cadence may fall further to protect freshness. These are
targets, not guarantees about a device or network.

Only VideoSource output is scaled. MediaProjection geometry, logical touch
coordinates, renderer, control channels, and AI behavior are unchanged. Hardware
H.264 preference and shared EGL were already present. Vendor-safe software
fallback remains available. The pinned Android VideoTrack API has no browser-style
contentHint setter; no unsupported API or isScreencast workaround is added.

Validation: 54 focused JVM tests passed, including ten new source-activity and
motion-budget tests. The regression suite covers the earlier 6 FPS / 53 ms encode /
585 ms send-queue trace, recovery hysteresis, receiver stalls, rotation, and severe
network fallback. Full Android tests, lint, and APK assembly run in the PR workflow.
The new recording shows the controller view but provides no synchronized RTP
telemetry. No physical two-phone comparison or measured visual FPS gain is claimed.
