# Architecture

## Planes

1. **Session plane** — strict state machine and fail-closed session guard.
2. **Pairing plane** — Firebase anonymous identity + callable functions for short-lived single-use codes.
3. **Signaling plane** — Realtime Database SDP/ICE exchange scoped to the two session participants.
4. **Media plane** — MediaProjection -> WebRTC video track -> controller renderer.
5. **Control plane** — compact WebRTC data messages -> generation-aware coordinate mapper -> AccessibilityService gestures.
6. **Safety plane** — no valid LIVE lease means no gesture execution; STOP/network loss/projector stop revokes the lease.

## Session states

IDLE -> SETUP_REQUIRED -> READY -> CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_CONSENT -> CONNECTING -> LIVE -> CLOSED

Every transition is monotonic for a session. A closed session is never revived.

## Latency policy

Control responsiveness wins over visual quality. Video bitrate/resolution may degrade under congestion; command traffic is isolated from the video track. Stale display generations and stale gesture packets are discarded.

## Coordinate policy

Controller touch points are mapped through the actual rendered remote-video rectangle, normalized to [0,1], then transformed into the latest remote display generation. Touches outside the video viewport are ignored.
