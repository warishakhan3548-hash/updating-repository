# Aaris Remote 1.9.6 — input-first realtime + faster AI targeting

## Realtime transport

Screen pixels continue to use WebRTC directly or through TURN. Cloudflare Workers remain the authentication, signaling, and TURN-credential control plane; they do not proxy steady-state screen video.

Decoder-health and EGL-presentation telemetry now use the existing unordered, non-retransmitted `control-live-v1` freshness lane after it opens. Startup keeps the reliable fallback. Old telemetry therefore cannot sit in retransmission head-of-line ahead of a newer authoritative tap, gesture START/END, navigation, or text command. Host feedback remains lease/display-generation bound and replay protected.

## AI hands

AI tap coordinates remain universal, including custom views and canvases. When the fresh Accessibility snapshot exposes an enabled clickable node under the requested point, the tap is centered inside the smallest matching target before the existing semantic and fresh-pixel revalidation. This reduces tiny-icon and edge-tap misses without introducing a second execution protocol.

`open_app` fast-paths an exact launcher package before enumerating launcher labels; conservative label matching remains the fallback.

## Observation latency

`phone_observe` no longer pays an unconditional 80 ms delay on an already-quiet screen. It returns immediately when the UI is already quiescent, otherwise waits only for 100 ms of quiet with the existing 320 ms ceiling. Privacy masking, fresh capture, one-use tickets, target revalidation, and the one-action contract stay intact.

## Regression gates

- Deterministic tests cover zero synthetic delay on quiet screens and bounded settling after invalidation.
- AI target-centering is verified against the smallest enabled clickable node.
- MCP protocol tests, Android unit tests, debug/release lint, and debug/release builds are required before commit.
- Cloudflare production topology is intentionally unchanged because Workers are not the video data plane.
