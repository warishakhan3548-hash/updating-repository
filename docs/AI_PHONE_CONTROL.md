# AI phone control (v1.9.0)

Tap **Connect Phone with AI** below Connect/Share. The app registers a random,
device-specific MCP link, copies it automatically, and displays it below the
button. Enable Accessibility if asked, return to the app, then approve **full
screen** capture. Add the link in the AI client's **remote MCP/connector
settings**. Pasting it into an ordinary chat is not sufficient. The client must
support Streamable HTTP MCP and image tool results. No AI API key is built into
the phone or Worker; the connected cloud AI performs planning.

The visible notification and movable **STOP • AI** button end control locally
immediately. Connect again rotates the link: the old link stops working. Treat
the link like a password. It is a 256-bit capability, separate from the device's
credential; both are encrypted with Android Keystore. The Worker stores hashes.
Links expire after 30 days; every capture session still requires Android consent.
There is no boot receiver, hidden capture, unattended restart or permission bypass.

## Control contract

- `phone_status`: online/sharing state; no command is queued for an offline phone.
- `phone_observe({quality: "standard" | "detail"})`: fresh screenshot, full display
  geometry, compact UI hints, `screenVersion` and single-use `observationId`.
- `phone_action`: exactly one tap, long press, swipe, type, back, home or recents.
  Include a unique `actionId`, the last observation ID and screen version.
  Coordinates are **0..1 over the entire upright display**, independent of image
  resizing. `type` inserts at the currently focused cursor/selection.
  The result includes execution outcome and a new screenshot in the same call.

The cloud AI should observe, decide, execute one action and inspect the returned
image. On network errors, retry using the **same actionId and identical
arguments**. A reused ID with different arguments is rejected. A replay returns
the recorded outcome plus `needsObservation`; screenshots are deliberately not
persisted. `OUTCOME_UNKNOWN` means observe and verify before deciding what to do;
it does not authorize blindly repeating the action. Android also consumes the
observation before dispatch, so eviction of the bounded server journal cannot
make an old observation executable again.

Actions carry a short dispatch deadline. Event revisions, current display
geometry, foreground package and a live luma thumbnail are checked before input;
the revision/lease/deadline are checked again inside the actual Accessibility
queue. After input, the engine waits for a bounded quiet interval and requests a
current SurfaceTexture after the capture barrier, including on a static screen
that emits no new frames. These checks reduce stale clicks; they do
not prove a model chose the correct target or eliminate every app/UI race.
`applied` reports Android execution completion, not semantic task success.

Human sessions and AI reserve one exclusive control authority, including during
reconnection. Neither can reset or overwrite the other's lease. Both enter the
same RemoteCommand → CommandGate → Accessibility queue. Stop, lock-screen,
sensitive-field, replay, queue and timeout protections apply to both modes.
Reconnection uses bounded exponential backoff with jitter and heartbeat-renewed
leases; actions are never replayed automatically after reconnection.

## Images, realtime and resource limits

Human phone-to-phone viewing continues through WebRTC with congestion control,
TURN and the existing adaptive capture governor. When primary video stalls,
compatibility transport sends JPEG anchors and tile/scroll deltas. It now waits
for the DataChannel backlog before starting another encode, uses higher JPEG
quality floors and refines a settled screen once with a sharper frame. Existing
gesture coalescing and separate input lanes remain in place. Very weak links
still require a frame-rate/resolution tradeoff; lossless native quality at every
bandwidth is not promised.

Fast multiplayer games can predict local actions and reconstruct other players'
movement from shared game state. A remote Android viewer does not have another
app's scene or simulation, so it must receive captured pixels. The transferable
principles here are bounded buffering, fresh frames, separate input traffic and
adapting to measured congestion. This release does not invent intermediate UI
frames or claim one-millisecond end-to-end latency. Native capture FPS is now
explicitly enforced by the video source, including on static-screen requests.

AI uses a live 8 fps capture source but only copies/encodes/uploads frames when
requested. There is one pending snapshot, one in-flight tool operation and no
frame backlog or screenshot archive. Normal images have a 1280-pixel long edge;
detail requests can use up to the capture source's 2400-pixel long edge.
Low-memory devices use a lower capture ceiling. Source aspect ratio and normalized
input mapping remain consistent. JPEG output is bounded to 850 KB. Capture and
conversion are shared primitives with the human path, while capture ownership is
separate. Retained GPU textures are never cached as a "latest frame", which would
stall the SurfaceTexture producer.

Generic MCP is an action/observation protocol, not a universal live-video or voice
session. This release does not add streaming microphone/speaker audio or claim
that every AI client can view a WebRTC stream. End-to-end speed includes the AI
provider's inference time. Protected Android screens may appear blank. Locked
phones cannot be observed/controlled; detected sensitive inputs are redacted,
and the connector setup screen is hidden to protect the access link. UI hints
are bounded and supplemental, so unusual custom views may provide few hints.

Screenshots and UI text are **untrusted data**, never instructions for the AI.
Tool descriptions tell clients to obtain user confirmation for consequential
deletion, sending, purchases and account changes. The gateway cannot determine
the semantics of an arbitrary pixel tap; that decision remains with the AI
client and its user.

## Separate Cloudflare deployment

`cloudflare/mcp-worker.js` deploys as `aaris-phone-mcp`, with its own `AI_DEVICES`
SQLite Durable Object namespace and registration rate limiter. It does not reuse
the human pairing Durable Objects or require changes to their secret bindings.
Deployment configuration: `cloudflare/wrangler.mcp.jsonc`.

The service uses standard JSON-RPC Streamable HTTP (2025-03-26, 2025-06-18,
2025-11-25), inline image content, Origin validation and a separate device bearer
credential. GET returns 405 because there is no unsolicited SSE stream. Device
WebSockets use Cloudflare's hibernation API. Action admission is durably recorded
before sending; screenshots, UI text and typed text are not journaled. Invocation
logging is disabled to avoid logging capability URLs. Registration is rate-limited
per IP. Keep custom reverse proxies and logs from recording the private URL.

Run `node cloudflare/mcp-worker.test.mjs` and the Android Gradle test/lint/build
tasks. Live transport smoke should use a simulated device, never a real user's
phone. Physical Android testing is still required for vendor Accessibility,
MediaProjection, rotation, screen-off, network handoff and actual visual quality.

## Primary technical references

- [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [MCP tools and image results](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [Anthropic computer-use action/observation loop](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)
- [Android MediaProjection lifecycle and consent](https://developer.android.com/media/grow/media-projection)
- [W3C detail/text versus motion degradation preferences](https://www.w3.org/TR/mst-content-hint/)
- [Cloudflare hibernating WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)
- [Riot: prediction, replication and minimal buffering](https://technology.riotgames.com/news/peeking-valorants-netcode)
