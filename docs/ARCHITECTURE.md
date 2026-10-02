# Aaris Remote architecture

## Design goal

Aaris Remote keeps the Cloudflare control plane separate from the actual
screen/control transport. Cloudflare authenticates a session, stores bounded
signaling history and issues short-lived TURN credentials. Screen frames and
remote-control packets flow through WebRTC, not through the Worker.

The connection architecture follows the same public design principles used by
mature remote-access systems:

- keep the connection/session owner alive before media starts;
- prefer a direct path when it works, but have a relay candidate ready;
- treat signaling reconnect as different from media transport failure;
- persist/replay signaling so a late/reconnecting peer does not require a new
  pairing session;
- use ICE restart/renegotiation instead of destroying a healthy authenticated
  session after a route handoff;
- apply bounded exponential-style backoff rather than tight retry loops.

## Production tree map

### Android UI / lifecycle

- `ui/MainActivity.kt`
  - creates/redeems one-time pairing codes;
  - persists pending controller/host session identity;
  - launches the controller connection monitor immediately after redeem.
- `webrtc/ControllerConnectionService.kt`
  - foreground controller connection owner started directly by the user's Connect action;
  - survives Activity navigation and owns backend observation + controller WebRTC;
  - prewarms TURN/WebSocket/RECV_ONLY peer at HOST_APPROVED;
  - keeps signaling alive even when the remote-view Activity is not present.
- `webrtc/ControllerConnectionRuntime.kt`
  - process-scoped transport handoff between the foreground service and viewer UI;
  - caches live geometry/video track/connection state for late UI attachment.
- `ui/RemoteControlActivity.kt`
  - presentation/control surface only;
  - launches after backend LIVE instead of being required to establish transport;
  - attaches to the already-running service-owned WebRTC session;
  - lazily creates the video renderer only after a remote track arrives;
  - exposes connection flight-recorder diagnostics.

### Session state

- `session/SessionStateMachine.kt`
  - local deterministic transition guard.
- `session/SessionCoordinator.kt`
  - process-wide local session authority.
- Cloudflare Durable Object remains the network/session authority.

Authoritative backend flow:

`CODE_ACTIVE -> PAIR_PENDING -> HOST_APPROVED -> SCREEN_READY -> LIVE -> CLOSED`

### Cloudflare control plane

- `cloudflare/core-worker.js`
  - `PairingDirectory`: code hash -> session ID, short-lived and single-use;
  - `AarisSession`: authenticated state, event history, WebSocket fanout;
  - bounded append-only events with monotonic sequence numbers;
  - Durable Object WebSocket backlog replay;
  - controller TURN prewarm allowed only after HOST_APPROVED;
  - SDP/candidate media signaling remains blocked until SCREEN_READY/LIVE;
  - short-lived Cloudflare Realtime TURN credentials.

### Android Cloudflare client

- `backend/CloudflareBackend.kt`
  - HTTPS/WebSocket request construction and token storage.
- `pairing/CloudflarePairingGateway.kt`
  - create/redeem/approve/state polling and deadline recovery.
- `webrtc/CloudflareSignalingClient.kt`
  - WebSocket signaling;
  - sequence-aware reconnect cursor;
  - SDP/candidate event publishing;
  - negotiation-ID correlation;
  - exact-offer redelivery instead of generating competing negotiations.

### WebRTC transport

- `webrtc/WebRtcPeer.kt`
  - Unified Plan peer connection;
  - host SEND_ONLY screen transceiver;
  - controller RECV_ONLY video transceiver created before offer replay;
  - ordered `control-v1` DataChannel;
  - direct + STUN + TURN candidates available in the initial negotiation;
  - relay-only escalation reserved for recovery;
  - network handoff observer and ICE restart;
  - bounded/adaptive offer redelivery.
- `webrtc/IceServerProvider.kt`
  - Cloudflare TURN + STUN configuration with deterministic fallback.
- `webrtc/ControllerWebRtcSession.kt`
  - controller transport/control protocol owner;
  - WebRTC may preconnect at HOST_APPROVED;
  - HELLO timeout is armed only after SCREEN_READY, so host consent time does
    not consume the media-handshake timeout.
- `webrtc/HostWebRtcSession.kt`
  - host capture track + SEND_ONLY negotiation + control handshake.

### Screen capture / control

- `capture/ScreenShareService.kt`
  - foreground MediaProjection owner on the sharing phone.
- `capture/ScreenCaptureTrack.kt`
  - WebRTC screen video source.
- `accessibility/AssistAccessibilityService.kt`
  - applies authenticated remote commands on the sharing phone.
- `control/ControlProtocol.kt`
  - bounded binary control protocol over the ordered DataChannel.

## Connection sequence

1. Phone A creates a one-time code.
2. Phone B redeems it and immediately starts the foreground controller connection service while MainActivity stays visible.
3. Phone A explicitly approves.
4. The service on Phone B preloads TURN, creates RECV_ONLY video, and opens signaling independently of any Activity.
5. Phone A obtains MediaProjection consent.
6. Backend becomes SCREEN_READY.
7. Phone A creates one SEND_ONLY SDP offer and stores/publishes it.
8. Phone B receives either the live event or Durable Object replay and creates
   the matching SDP answer.
9. Both sides trickle ICE candidates. Direct and relay candidates coexist.
10. ICE selects the best viable pair.
11. The ordered control DataChannel opens.
12. Host sends HELLO + display geometry.
13. Video renders and the backend can advance to LIVE.

## Waiting and retry policy

The backend CONNECT_TTL is 180 seconds. A host must not give up after a few
seconds merely because the controller/user is slow.

Pending SDP offer delivery therefore uses bounded backoff rather than a fixed
5-second loop. The same offer/negotiation ID is replayed; no competing SDP
generation is manufactured. Durable Object event history is also replayed on a
late/reconnected controller socket.

The controller HELLO watchdog starts only at SCREEN_READY, not at
HOST_APPROVED. Time spent by the host reading/accepting Android screen-capture
consent is therefore not counted as a WebRTC/media failure.

## Recovery hierarchy

1. WebSocket reconnect + sequence replay.
2. Re-publish the exact pending SDP generation with bounded backoff.
3. Wait for normal ICE settling after an answer.
4. ICE restart after genuine transport failure/network handoff.
5. Relay-focused recovery when a direct route remains unusable.
6. Close only after the authoritative session deadline or terminal protocol
   failure.

## Security boundaries

- pairing code is stored only by hash;
- host/controller credentials are opaque random tokens and persisted only as
  hashes server-side;
- TURN secrets never ship in the APK;
- controller cannot publish SDP/candidates before SCREEN_READY;
- MediaProjection always requires Android user consent;
- Accessibility is required only on the sharing/controlled phone;
- no lock-screen or secure-screen bypass is attempted.
