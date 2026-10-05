# Aaris Remote 1.9.10 — source-aware presentation and acknowledged hint reuse

## Execution map

Video: `MediaProjection -> ScreenCaptureTrack -> VideoSource adaptation -> VideoTrack -> hardware-first encoder -> WebRTC RTP/direct ICE or TURN -> decoder -> controller SurfaceView/EGL`.

Human input: `InlineRemoteControllerView -> reliable START/END or freshness-only live CONTINUE DataChannel -> HostWebRtcSession -> CommandGate -> AssistAccessibilityService -> Android gesture dispatch`.

AI: `Cloudflare MCP -> authenticated device socket -> AiConnectorService -> AiObservationEngine -> fresh capture + Accessibility snapshot -> observation ticket -> fresh target validation -> AiActionTranslator -> existing command/Accessibility engine`.

Cloudflare owns authorization, pairing, signaling, TURN credentials and the MCP bridge. Steady-state human screen pixels remain on WebRTC.

## Source-aware fast presentation

The fast presentation governor previously compared controller swaps with the configured 45/60 fps ceiling. A healthy 24/30 fps source could therefore look like a severely underperforming receiver and lose its capture ceiling. The slower RTC stats governor already uses measured sender/receiver rates, but the faster path could act first.

The existing capture probe now feeds the same bounded cadence sampler used for EGL timing. This observes source-admitted frames before encoder/network/decoder pressure, retains no frame buffers and adds no stats polling. Fresh source samples expire after 750 ms; absent/invalid evidence retains the existing fallback behavior.

`FastPresentationGovernor` compares delivered frames against the smaller of the configured ceiling and measured source supply. Source-limited content does not earn higher-FPS probes or failed-probe penalties. When actual source supply exercises the current cap, healthy presentation can still probe upward. Receiver shortfall and severe render gaps retain fast relief, hysteresis and failed-60-fps backoff. WebRTC remains responsible for bitrate and packet pacing.

Dependency impact: the timing sampler adds a synchronized, non-consuming recent-window read; HostWebRtcSession supplies it to the existing governor. No input protocol, projection lifecycle, codec, network transport or SurfaceView replacement is introduced.

## Acknowledged exact hint reuse

`phone_observe` and `phone_action` accept optional `knownUiHintsObservationId`. It identifies a previous full hint list the caller actually has in its context. Omit it to request complete hints.

For semantic/motion observations only, a large (at least 512 serialized characters), exactly unchanged list may become:

```json
{
  "observationId": "new-ticket-id",
  "screenVersion": 12,
  "uiHints": [],
  "uiHintsDelivery": "reused",
  "sameUiHintsAsObservationId": "acknowledged-full-list-id"
}
```

The caller uses the referenced hints with the NEW ticket for its next action. The reference stays attached to the last full list; reused observations never create reference chains. An unknown/unacknowledged base yields full hints, so another MCP client or a lost response cannot silently remove needed semantics. Omitting the acknowledgement fetches a new full base without requiring a higher-cost visual mode.

Reuse requires exact published text, bounds, target IDs, focused/enabled state, package/window, full-display dimensions and rotation. Privacy masks, hidden screens, truncated trees, unstable capture, standard/detail or region requests cannot reuse hints. Cache retention is one bounded full list per observation engine, with a 60-second lifetime. Failed actions and stale-screen recovery publish complete hints. Changed game pixels remain visual even when native overlay hints match.

Only delivery text is reduced. Full Accessibility nodes, fresh captures/fingerprints, generation checks, one-action admission, idempotency, sensitive-input handling and gesture validation remain authoritative. Existing drag/two-finger game primitives continue to use that engine; this change does not claim autonomous game skill or real-time model inference.

## Validation and practical limits

Regression tests cover healthy 15/24/30 fps sources, real receiver stalls, source freshness/reset, recovery when the cap is exercised, caller acknowledgement, exact hint equality, changed motor state, geometry/window/privacy races, truncation, expiry, reference chains and changed game images through MCP.

Required CI remains Android unit tests, debug/release lint, debug/release assembly, MCP protocol tests and the live Cloudflare control-plane smoke test. Android changes require installation of the updated APK on the sharing phone. Physical two-phone glass-to-glass latency, sustained playback, thermal behavior and token counts still require device/provider measurements; no fixed latency or savings percentage is asserted.

Primary references:

- [Meta: Adopting AV1 for Real-Time Communication at Scale](https://engineering.fb.com/2026/06/22/video-engineering/adopting-av1-for-real-time-communication-rtc-meta/) — measured encoder/decoder capability and rate-control pressure.
- [W3C WebRTC Stats](https://www.w3.org/TR/webrtc-stats/) — frame, decode and jitter-buffer measurement semantics.
- [Android: Low-latency MediaCodec decoding](https://source.android.com/docs/core/media/low-latency-media) — device/driver-dependent low-latency support; no unverified codec toggle is forced.
