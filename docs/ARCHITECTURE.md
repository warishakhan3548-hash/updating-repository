# Aaris Remote architecture

## Control plane

Version 1.8+ has one remote authority: Cloudflare.

Each remote-support session is represented by a SQLite-backed `AarisSession` Durable Object. A second SQLite-backed `PairingDirectory` Durable Object atomically maps a short-lived hash of the one-time code to the random session identifier.

The Android app uses an opaque host or controller token for every session request. Only token hashes are persisted.

## Pairing

1. Host requests a session.
2. Worker generates a random 64-hex session ID, random host credential, and 12-digit code.
3. The pairing directory stores only `SHA-256(code) -> sessionId + expiry`.
4. Controller redeems the code exactly once.
5. The directory entry is consumed and removed.
6. Host must explicitly approve before screen-sharing setup continues.

## Signaling

SDP descriptions, ICE candidates, ICE-restart requests, and advisory presence are append-only session events. Every event has a monotonic sequence number and sender role. The session keeps a bounded replay window.

The live signaling connection uses Cloudflare Durable Object WebSocket Hibernation. After reconnect, the Android client asks for events after its last sequence before continuing with live delivery.

Negotiation IDs remain `client-instance:epoch`; stale generations are rejected and answers may bind to an exact offer with `replyToNegotiationId`.

## TURN and WebRTC

After `SCREEN_READY`, either authenticated peer can request short-lived Cloudflare Realtime TURN credentials. Long-lived TURN credentials exist only as Cloudflare Worker secret bindings.

Cloudflare is not in the screen-frame or remote-command data path:

`MediaProjection -> WebRTC video`

`ordered control-v1 DataChannel -> host Accessibility service`

Accessibility is required only on the sharing/controlled phone.

## Failure model

A signaling reconnect is not a transport failure. WebRTC peer state plus the ordered control DataChannel determine connectivity. SDP/candidate publication uses bounded retry, signaling reconnect uses sequence replay, and the host keeps bounded ICE-restart/relay escalation for startup recovery.
