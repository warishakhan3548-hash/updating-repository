# Aaris Remote 1.9.5 — presentation-aware realtime + faster AI hands

## End-to-end architecture

Human control path:

`controller touch -> control-live-v1/control-v1 -> host Accessibility -> MediaProjection -> WebRTC encoder -> direct ICE/TURN -> controller decoder -> EglRenderer -> TextureView`

Cloudflare `aaris-remote-ice` remains the signaling/TURN-credential control plane. It does **not** proxy steady-state screen video, so no placebo Worker placement/CPU change is used to claim lower video latency.

AI path:

`phone_observe -> target validation -> one action -> fresh observation`

The existing one-action safety contract remains intact.

## Realtime upgrades

- The controller now reports **actual EGL presentation cadence** (real displayed swaps), not only RTP/decoder counters.
- The host merges decoder + presentation feedback only for the current lease/display generation and rejects replayed sequences.
- The cadence governor now sees controller-side render starvation and long frame gaps. When severe pressure is measured, it may jump directly from 60 fps to a sustainable lower rung instead of spending several 3-second epochs accumulating stale frames.
- Recovery remains deliberately slower than degradation to avoid oscillation.
- Live gesture `CONTINUE` packets are no longer inserted into the command-ACK latency tracker because the host intentionally never ACKs them. This prevents long drags from evicting useful authoritative ACK samples.

## AI hand upgrade

`phone_action` gains optional `open_app` with an `app` label/package argument. Android resolves only launcher-visible installed apps and uses conservative deterministic matching. Ambiguous names fail closed, so the AI can fall back to the existing Home/Search/tap flow instead of opening a guessed app.

The action still requires a fresh observation ticket, the active AI lease, unchanged display geometry, and the existing explicit foreground screen-sharing session.

## Regression coverage

- Presentation window timing/max-gap tracking.
- Presentation packet wire round-trip and malformed-packet rejection.
- Lease/generation/replay-safe merge of decoder and presentation feedback.
- Direct severe-presentation-jank cadence reduction and healthy 60 fps stability.
- Conservative app-label/package matching.
- MCP schema validation for `open_app`.
