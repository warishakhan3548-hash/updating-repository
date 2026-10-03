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
- apply bounded exponential-style backoff rather than tight retry loops;
- keep authoritative commands reliable while allowing stale pointer-motion
  samples to be dropped instead of building input lag;
- adapt capture cost slowly from transport/encoder telemetry instead of
  reacting to one noisy network sample.

## Production tree map

### Android UI / lifecycle

- `ui/MainActivity.kt`
  - creates/redeems one-time pairing codes;
  - persists pending controller/host session identity;
  - launches the controller connection monitor immediately after redeem;
  - opens the inline remote viewer only after the service-owned connection is
    ready.
- `webrtc/ControllerConnectionService.kt`
  - foreground controller connection owner started directly by the user's
    Connect action;
  - survives Activity navigation and owns backend observation + controller
    WebRTC;
  - prewarms TURN/WebSocket/RECV_ONLY peer at HOST_APPROVED;
  - keeps signaling alive even when the remote-view UI is not present.
- `webrtc/ControllerConnectionRuntime.kt`
  - process-scoped transport handoff between the foreground service and viewer
    UI;
  - caches live geometry/video track/connection state for late UI attachment.
- `ui/InlineRemoteControllerView.kt`
  - full-screen presentation/control surface inside `MainActivity`;
  - uses a TextureView-backed EGL renderer in the same Android view hierarchy
    as controls;
  - lazily attaches the service-owned remote video track;
  - aspect-fits remote pixels and uses the same geometry contract for touch
    mapping;
  - sends long drags as streamed gesture segments instead of waiting for the
    final finger-up event;
  - automatically hides the bottom dock after primary video renders and parks a
    small side handle so remote bottom navigation remains usable;
  - forwards taps/swipes made on the parked edge handle to the remote screen.

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

- `webrtc/WebRtcRuntime.kt`
  - shared EGL context for capture/codecs/rendering;
  - hardware-first default Android encoder/decoder factories with software
    fallback.
- `webrtc/WebRtcPeer.kt`
  - Unified Plan peer connection;
  - host SEND_ONLY screen transceiver;
  - controller RECV_ONLY video transceiver created before offer replay;
  - ordered `control-v1` DataChannel for authoritative commands;
  - unordered, non-retransmitted `control-live-v1` lane for freshness-only drag
    CONTINUE packets plus stale-safe decoder/presentation telemetry;
  - separate unordered fallback-video lane;
  - direct + STUN + TURN candidates available in the initial negotiation;
  - relay-only escalation reserved for recovery;
  - network handoff observer and ICE restart;
  - bounded/adaptive offer redelivery.
- `webrtc/InteractiveVideoPolicy.kt`
  - keeps idle STANDARD/HIGH tiers clarity-first;
  - uses balanced WebRTC degradation during interaction on STANDARD/HIGH so
    smoothness does not require an abrupt resolution cliff;
  - keeps LOW/BALANCED tiers freshness-first during interaction because their
    capture size is already bounded.
- `webrtc/IceServerProvider.kt`
  - Cloudflare TURN + STUN configuration with deterministic fallback.
- `webrtc/ControllerWebRtcSession.kt`
  - controller transport/control protocol owner;
  - WebRTC may preconnect at HOST_APPROVED;
  - HELLO timeout is armed only after SCREEN_READY, so host consent time does
    not consume the media-handshake timeout.
- `webrtc/HostWebRtcSession.kt`
  - host capture track + SEND_ONLY negotiation + control handshake;
  - refreshes the interaction-policy watchdog from live gesture traffic so a
    long drag does not fall back to idle video policy mid-gesture;
  - drives capture-tier adaptation from outbound WebRTC telemetry.

### Screen capture / adaptive quality

- `capture/ScreenShareService.kt`
  - foreground MediaProjection owner on the sharing phone.
- `capture/ScreenCaptureTrack.kt`
  - one MediaProjection-backed WebRTC screen source;
  - changes capture format in-place instead of creating a second projection.
- `capture/CaptureProfile.kt`
  - device-aware LOW/BALANCED/STANDARD/HIGH resolution, FPS and bitrate
    ceilings.
- `capture/CaptureQualityGovernor.kt`
  - asymmetric hysteresis for CPU/network pressure and quality recovery;
  - packet loss/RTT corroborate bandwidth pressure before sacrificing capture
    resolution.
- `webrtc/FallbackScreenStreamer.kt`
  - low-FPS compatibility pixels only when primary RTP video is black;
  - consumes the same capture track so Android 14+'s one-projection constraint
    is respected;
  - drops stale fallback work rather than competing with normal remote control.

### Remote input / safety

- `control/ControlProtocol.kt`
  - bounded binary control protocol.
- `control/CommandGate.kt`
  - authorization + replay/order gate;
  - authoritative controls and freshness-only CONTINUE packets have separate
    monotonic clocks so unordered live motion cannot invalidate a reliable
    START/END command.
- `accessibility/AssistAccessibilityService.kt`
  - applies authenticated commands on the sharing phone;
  - serializes Android gesture dispatch while coalescing queued stale CONTINUE
    segments from the same live stream;
  - rejects remote interaction on locked devices and sensitive focused fields;
  - keeps the local STOP overlay reachable and relocates it away from an
    intersecting remote command before injecting that gesture.

## Connection sequence

1. Phone A creates a one-time code.
2. Phone B redeems it and immediately starts the foreground controller
   connection service while MainActivity stays visible.
3. Phone A explicitly approves.
4. The service on Phone B preloads TURN, creates RECV_ONLY video, and opens
   signaling independently of any Activity/viewer.
5. Phone A obtains MediaProjection consent.
6. Backend becomes SCREEN_READY.
7. Phone A creates one SEND_ONLY SDP offer and stores/publishes it.
8. Phone B receives either the live event or Durable Object replay and creates
   the matching SDP answer.
9. Both sides trickle ICE candidates. Direct and relay candidates coexist.
10. ICE selects the best viable pair.
11. Reliable control and freshness-only live-control DataChannels open.
12. Host sends HELLO + display geometry.
13. Video renders, the inline viewer binds the remote track, and the backend can
    advance to LIVE.

## Interactive media policy

Normal screen sharing and active control are intentionally different media
states.

While idle, STANDARD/HIGH tiers protect screen readability with a
resolution-preserving sender policy. During active touch on those tiers, the
sender uses WebRTC's BALANCED degradation mode so congestion control can trade
small amounts of temporal/spatial quality without immediately turning text into
a low-resolution image. LOW/BALANCED tiers favor frame freshness while active,
because the capture size is already constrained.

The interaction state has a controller-provided end signal and a host watchdog.
Live gesture stream traffic refreshes that watchdog, so a multi-second drag or
scroll remains in interactive media mode for the entire gesture even if the
initial InteractionState packet was sent several seconds earlier.

WebRTC congestion control remains authoritative for packet pacing and the real
send rate. The app supplies ceilings and capture-cost decisions; it does not
force the network to carry the configured maximum bitrate.

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
6. If primary RTP pixels are black while control is healthy, recover video
   without tearing down the authenticated/control session.
7. Close only after the authoritative session deadline or terminal protocol
   failure.

## Security boundaries

- pairing code is stored only by hash;
- host/controller credentials are opaque random tokens and persisted only as
  hashes server-side;
- TURN secrets never ship in the APK;
- controller cannot publish SDP/candidates before SCREEN_READY;
- MediaProjection always requires Android user consent;
- Accessibility is required only on the sharing/controlled phone;
- the local STOP affordance remains reachable during sharing;
- remote gestures are blocked on locked devices and sensitive focused input;
- no lock-screen or secure-screen bypass is attempted.
