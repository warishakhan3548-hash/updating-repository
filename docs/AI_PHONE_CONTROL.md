# AI phone control (v1.9.22)

Tap **Connect Phone with AI** below Connect/Share. The app registers a random,
device-specific MCP link, copies it automatically, and displays it below the
button. Enable Accessibility if asked, return to the app, then approve **full
screen** capture. Add the link in the AI client's **remote MCP/connector
settings**. Pasting it into an ordinary chat is not sufficient. The client must
support Streamable HTTP MCP and image tool results. No AI API key is built into
the phone or Worker; the connected cloud AI performs planning.

Wait for **AI connected** before leaving for the AI app. "Link copied" only means
registration succeeded; Accessibility and Android screen-sharing consent still
have to complete. The AI status stays visible below the link. Wi-Fi internet is
sufficient; neither a SIM recharge nor mobile data is required.

The visible notification and movable **STOP • AI** button end control locally
immediately. Connect again reuses the saved link, so the AI client does not need
to be configured again. STOP closes the current phone session while the MCP
status tool remains authenticated and reports `stopped`. A run-scoped server
pause prevents delayed cleanup from an old service stopping a newer one. To
invalidate a shared link, stop control, hold the link and choose **Replace link**;
only then does the old URL stop working. Treat
the link like a password. It is a 256-bit capability, separate from the device's
credential; both are encrypted with Android Keystore. The Worker stores hashes.
Links expire after 30 days; every capture session still requires Android consent.
There is no boot receiver, hidden capture, unattended restart or permission bypass.

## Control contract

- `phone_status`: online/sharing state and a setup, connecting, stopped or
  disconnected explanation; no command is queued for an offline phone.
- `phone_observe({quality: "standard" | "detail"})`: fresh screenshot, full display
  geometry, compact UI hints, `screenVersion` and single-use `observationId`.
- `phone_action`: exactly one tap, long press, swipe, drag, two-finger gesture,
  type, back, home, recents or direct app launch. Include a unique `actionId`,
  the last observation ID and screen version. Coordinates are **0..1 over the
  entire upright display**, independent of image resizing. `type` inserts at
  the currently focused cursor/selection. The result includes execution outcome,
  a visual effect classification and a new screenshot in the same call.
- `phone_task`: bounded run-local working memory for the user goal, current
  subgoal, compact facts, recent actions and stall state. It intentionally does
  not persist screenshots or typed field contents.
- `phone_wait`: event-driven local waiting from the latest observation. The phone
  samples frames locally and sends no intermediate screenshots. A timeout returns
  compact metadata only; a meaningful whole-screen or optional region change
  returns one fresh screenshot. This is preferred over repeated observe calls
  while waiting for a turn, animation, loading state or asynchronous update.
- `phone_burst`: a bounded 1-4 step touch-only motor program for tightly
  coupled same-scene interactions. It supports tap, long-press, swipe, drag and
  two-finger gestures, runs under a small local time budget, aborts if the
  foreground/window/geometry or scene changes unexpectedly, and always returns a
  fresh checkpoint observation. It is disabled on strict/form/sensitive screens.
- `phone_reflex`: waits locally for a previously remembered benign tap-state to
  leave and reappear, executes that tap exactly once, then returns a fresh
  screenshot. It is short-lived, one-shot and guarded by app/window/geometry,
  local pixels and, when available, Accessibility target identity.

### Guarded short motor bursts

v1.9.22 adds a bounded motor-burst primitive for fast interactive surfaces. The
model can group a few tightly coupled touch actions into one local execution
window instead of paying a cloud round-trip between every finger movement. The
phone validates the first target against the latest observation, rechecks it at
dispatch time, keeps app/window/geometry/session guards active for every step,
and takes raw-frame checkpoints between steps. A large scene transition aborts
the remaining steps and returns control to the model with one fresh screenshot.

Bursts are intentionally not a general scripting engine: only touch gestures are
allowed, the step count and total motor budget are small, forms/sensitive screens
are excluded, and consequential actions should remain individually reviewed.

### Event-driven observation and target-aware progress

v1.9.21 adds local change waiting so the cloud model does not need to spend image
tokens repeatedly polling an unchanged or irrelevant screen. `phone_wait` can
watch the full display or a normalized rectangular region. Region watches are
useful for turn indicators, dice/results, loading areas and other small state
signals while unrelated timers or background animation continue elsewhere.
Timeout responses contain no screenshot; meaningful changes return one fresh,
validated observation.

Action-effect feedback now separates whole-screen motion from change around the
intended touch/field path. If the background animates but the intended target
does not react, the result is `background_motion_only` rather than false
progress. Stale/refused attempts are also recorded in bounded task trajectory
memory with their result code, helping the model avoid repeating the same failed
strategy.

### Stateful planning and guarded local reflexes

v1.9.20 adds a bounded agent-state layer instead of treating every screenshot as
an isolated decision. Multi-step clients should start a `phone_task` with the
user's goal, attach concise `intent` and `expectedOutcome` fields to actions,
and use the returned `effect` plus `taskState` to verify progress. Repeated
no-effect or failed actions raise a stall signal so the model can re-observe or
change strategy rather than looping blindly.

Observations now include an `interactionMode`. Editable/form-like screens stay
strict. Low-semantics animated custom canvases can enter `dynamic_canvas`, where
target-local animation no longer invalidates every coordinate tap; foreground
window, geometry, privacy, lease and semantic target checks remain enforced.
This improves games and other custom-rendered apps without weakening sensitive
form handling.

For a repetitive benign tap, the model may set `rememberReflexId` on a validated
tap. The phone records only a short-lived visual/semantic guard, not a macro or
screen archive. A later `phone_reflex` call watches that small local state at the
capture cadence. The reference must first depart and then reappear before a
one-shot tap is allowed, preventing immediate double taps. The result returns a
fresh screenshot so the cloud model can analyze the new value/state before making
the next decision. Reflexes are cleared on stop/rotation and are not intended for
sending, deletion, purchases, account/security changes or uncertain targets.

The cloud AI should observe, decide, execute one action and inspect the returned
image. On network errors, retry using the **same actionId and identical
arguments**. A reused ID with different arguments is rejected. A replay returns
the recorded outcome plus `needsObservation`; screenshots are deliberately not
persisted. `OUTCOME_UNKNOWN` means observe and verify before deciding what to do;
it does not authorize blindly repeating the action. Android also consumes the
observation before dispatch, so eviction of the bounded server journal cannot
make an old observation executable again.

Observation tickets expire after 90 seconds and are single-use. Accessibility
events guide a bounded settling wait; they no longer revoke an observation just
because streaming text, a floating window or an overlay keeps updating. A coherent
observation can have `settled: false` and still authorize an action. Window/privacy
changes during capture fail closed without returning an unmasked image.

Before tap/long press, fresh upright color samples around the target and the local
Accessibility target are compared. Swipes compare the padded path; animation
elsewhere does not invalidate either. Typing binds the focused field, full-value
digest and selection. A changed foreground window, target, geometry, expired ticket
or disconnect still blocks input. Home requires no static pixels; Back/Recents
require the same foreground window but allow animation. Errors include a specific
`reason` and, when capture is available, a fresh image/ticket for a new decision.

Actions carry a 500 ms validation-to-dispatch deadline. Window/target state,
lease and deadline are checked again inside the actual Accessibility queue,
including after STOP moves out of the way. After input, the engine waits for a
bounded quiet interval (at most about 320 ms) and requests a
current SurfaceTexture after the capture barrier, including on a static screen
that emits no new frames. These checks reduce stale clicks; they do
not prove a model chose the correct target or eliminate every app/UI race.
`applied` reports Android execution completion, not semantic task success.

Human sessions and AI reserve one exclusive control authority, including during
reconnection. Neither can reset or overwrite the other's lease. Both enter the
same RemoteCommand → CommandGate → Accessibility queue. Stop, lock-screen,
sensitive-field, replay, queue and timeout protections apply to both modes.
Reconnection uses bounded exponential backoff with jitter and heartbeat-renewed
leases. Default-network changes reconnect the socket promptly, using Android's
chosen Wi-Fi/mobile route; late callbacks from obsolete sockets are ignored.
Actions are never replayed automatically after reconnection. Keystore/native
initialization runs off the UI thread, after foreground-service promotion, and
startup errors leave a visible retry instruction. The supplied v1.9.1 recording
identified a separate `NetworkOnMainThreadException` during `AiConnectorBackend.close()`:
OkHttp pool eviction closes TLS sockets and can write `close_notify`. v1.9.2 runs
all backend cancellation, pool eviction and executor shutdown on a process-owned
IO scope, including Activity `finally` and service destruction. Cleanup is
idempotent and outlives a cancelled UI scope. A real keep-alive socket regression
fails with the old synchronous close and passes with this implementation. This
fix allows setup to continue through capture consent; link registration alone
still does not mean the phone is online.

## Images, realtime and resource limits

Human phone-to-phone viewing continues through WebRTC with congestion control,
TURN and the existing adaptive capture governor. When primary video stalls,
compatibility transport sends JPEG anchors and tile/scroll deltas. It waits
for the DataChannel backlog before starting another encode and refines a settled
screen once with a sharper frame. v1.9.2 samples the capture source before RTP
resolution adaptation, releases the GPU texture before JPEG/delta encoding and
network work, and requests a current sample every 500 ms during recovery so a
static screen can finish refinement. Motion is bounded to a 1600-pixel long edge;
settled recovery can use up to the source resolution, capped at 2560 pixels.
Dependent delta packets use ordered delivery with bounded retransmission;
missing packets still require a new anchor. Existing
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

### Recovery rendering and responsiveness fixes

- Recovery compositing uses explicit pixel rectangles and density-free bitmaps.
  A native-graphics regression reproduces the old float-position Canvas overload
  expanding patches on 320/440/560 dpi surfaces. JPEG dimensions are checked before
  decoding; mismatches request a fresh anchor instead of stretching an image.
- The controller service now forwards delta frames to the viewer. Previously its
  listener inherited a no-op callback, so updates between JPEG anchors were lost.
  Decode and posted UI work are bounded; a missing base requests a new full frame.
- The MediaProjection surface remains at its initial device-appropriate ceiling.
  FPS/network tiers adapt downstream through VideoSource; only actual display
  size/orientation changes resize capture. This avoids repeated VirtualDisplay
  surface rebinding during touch bursts and congestion recovery. Static texture
  requests receive monotonic sample timestamps so native FPS adaptation can pass
  the recovery sample. Real-device rotation/vendor scaling still needs validation.
- Controller touches get immediate local markers. They acknowledge local touch,
  not successful host input. The remote dock's **Stats** view reports command ACK
  p50/p95 on the controller's clock, cumulative average jitter/codec delay, dropped
  frames, freezes and ICE candidate types where the SDK exposes them. ACK time is
  explicitly not input-to-photon latency; no frame causality is fabricated.

The viewer keeps bounded primary-video recovery active while compatibility
images are visible. Recovery requests no longer disable the host video track.
Only a real EGL swap confirms primary-video recovery; decoded RTP counters do
not. The SDK's persistent render callback replaces its one-shot screenshot
callback, so later stalls can recover too. Hardware baseline H264 is preferred
when the SDK reports support; VP8 remains negotiable. After repeated requests,
one supported alternate-codec offer is allowed in the existing peer without
restarting ICE, control or capture. The alternate must appear in both peers'
capabilities. High-profile H264 is not forced. These SDK calls compile against
`io.github.webrtc-sdk:android:150.7871.01`; codec/vendor behavior still requires
physical phone testing.

Recovery progress never covers a visible remote screen. It is available through
**Stats**; before the first image, a centered waiting placeholder is shown.

Hardware codecs, 60 fps interaction tiers, network adaptation and split
input channels are retained. Predictive scroll, forced zero jitter buffering and
thermal-headroom tuning are not added. The current native SDK's public
RtpReceiver API has no playout-delay setter. These changes target observed
defects rather than promising an unmeasured latency improvement.

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
