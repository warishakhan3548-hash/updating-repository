# Connect with AI through link

Tap **Connect with AI through link** in Aaris Remote. The app creates a new
session and copies its URL automatically. Enable Accessibility if needed, accept
Android's entire-screen sharing prompt, and paste the link into an AI that can
operate a browser. Opening the URL shows the entire phone in **AI view**: one
observation image stays visible while the AI decides. **Live view** selects the
existing WebRTC video. There is no web
login, OTP, CAPTCHA, microphone or camera request. If a browser blocks muted
autoplay, a Show phone button is available.

The existing **Connect Phone with AI** MCP mode remains separate and unchanged.
The browser button becomes **Stop AI Link** while sharing. Tap the status text
to copy the same active URL again. STOP on the phone's visible notification
also ends the session. A cancelled or ended link cannot restart capture.

## Reused engine

The new mode uses `ScreenShareService` → `HostWebRtcSession` → the existing
MediaProjection/WebRTC hardware video pipeline. Browser gestures encode the
same `ControlProtocol` v1 binary packets as the Android controller. Android's
existing Accessibility executor handles them. No second MediaProjection or
gesture executor is added. The existing BrowserAgentBridge uses that projection
for the authenticated HTTPS observation/control lane when live RTP is unavailable.

`AarisSession` in the existing Cloudflare Worker owns signaling and temporary
controller capability. WebRTC attempts direct media connectivity with the
existing TURN fallback. The URL secret stays in the fragment; page preview
requests do not consume or claim the session. Browser WebSocket authorization
uses subprotocol headers with same-origin validation, not a query parameter.
Only one browser owner is admitted. Each document refresh advances a controller
epoch and replaces transport while retaining the original authorized capture.

## Universal AI JSON control

The browser link exposes a visible **AI Command JSON** box for cloud/browser AIs
that can read the live phone video but do not reliably click arbitrary pixels on
the video element. The AI pastes exactly one JSON action and presses **Execute AI
command**. The page fills the session nonce, the displayed observation id/version
and action id, then routes the command through the existing validated phone
Accessibility executor. Executing JSON never silently captures a replacement
screen and authorizes old coordinates against it. An expired image requires an
explicit **Fresh screenshot**.

Clickable **Tap phone** buttons expose observed targets as DOM controls. A label
inside a bounded clickable parent remains actionable. Button centers use the
full phone display, not browser-page coordinates. Raw X/Y controls stay visible
for any image point, including games and canvases without named targets.

Raw coordinates are the universal motor primitive and do not depend on Android
Accessibility semantics, so canvas/OpenGL/game surfaces remain controllable:

```json
{"action":"tap","x":0.73,"y":0.41}
```

Coordinates default to normalized full-phone coordinates from 0 to 1. Pixel
coordinates are also accepted when the phone geometry shown beside the command
box is easier for the AI to use:

```json
{"action":"tap","x":742,"y":1180,"space":"pixel"}
```

Named Accessibility targets are optional shortcuts, not a requirement:

```json
{"action":"tap","target":"YouTube"}
```

Other compact commands include `type`, `back`, `home`, `recents` and
directional `swipe`. Only one command is executed per fresh observation.
After the phone changes, the AI must inspect the new screen before issuing the
next command; this prevents a batch of stale coordinates from being replayed
against a different UI.

## Background and reconnect behavior

The foreground service owns video and input. Opening WhatsApp, Settings or
another app backgrounds the Activity without closing the sharing service.
Activity recreation does not own or destroy transport. Process death, the
Android Stop Sharing action, Accessibility loss, explicit STOP and expiry end
sharing; starting again requires fresh platform consent.

There are five minutes to finish setup and join. The session has a two-hour
upper limit. An established browser losing its control lease pauses input and
has up to sixty seconds to reconnect. Commands are not buffered for a future
connection. Returning transport receives a fresh lease; an old gesture callback
cannot ACK a new browser's reused sequence number.

A third-party AI process and its browser can still be suspended by their host
platform. This feature does not keep another app alive or guarantee that every
AI can operate a URL. No physical Android/OEM background-endurance claim is made
by the automated tests.

## Browser controls and verification

Click, long press and drag on the phone image or live video; empty letterbox space is
ignored. There are DOM buttons for Back, Home, Recent apps and vertical swipes,
plus text entry and normalized-coordinate taps. Actions require a loaded matching
observation image or a fresh rendered live frame, including matching display
aspect ratio. AI view pins its decision image until explicit refresh or an action
outcome; background polls cannot replace it. Coordinate controls stay disabled
until the image loads and the browser claim completes. Input is single-flight, bounded and
acknowledged, with no automatic replay after an ambiguous result.

In AI view, Fresh screenshot requests an observation through the existing
HTTPS/phone bridge and keeps the result interactive. In Live view it captures a
newly rendered video frame into a page-local image. HTTPS observations are held
temporarily by the session Durable Object; STOP removes them and their tickets
expire after 90 seconds. The first image is embedded in HTML with its observation
id, avoiding a second image-request race. A standalone JPEG is read-only; return
to the console to tap. Frame-decode and actual render callbacks feed the existing
telemetry protocol.

When the owner reads a supported AI chat on this same phone, the bridge may hold
the previously observed target image. Browser HTTPS actions and the visible-chat
adapter resume that target app, then recheck app, window, geometry, target and
fresh pixels. A changed scene is refused. Home and direct app launch do not need
to resume the old target. Protected screens remain protected.

The detailed code/state map is in [AI_LINK_SCREEN_AND_TAP_MAP.md](AI_LINK_SCREEN_AND_TAP_MAP.md).

Checks:

- `node --test cloudflare/browser-link.test.mjs`: session expiry, claims,
  ownership, origin checks, legacy sessions, packet fixtures and coordinate maps.
- `BrowserControlInteropTest`: Android decodes the same signed-int64, gesture
  and UTF-8 fixtures generated by the browser adapter.
- `node cloudflare/browser-webrtc.test.mjs` (Playwright/Chromium): actual RTP
  video and SCTP input between a synthetic host and the shipped console; checks
  tap, letterbox rejection, Back, swipe, drag, long press, text, screenshot,
  refresh/new epoch and disconnect. This is not an Android-device test.
- Repository CI also runs Android tests, debug/release lint, APK builds, the
  gaming governor lab, the existing MCP tests and the live legacy backend smoke.
- `python3 cloudflare/smoke-browser-link.py` checks the deployed browser page,
  claims, native/browser WebSocket handshakes, SDP, TURN, refresh and revocation
  with a synthetic host. Its temporary session is closed in `finally`.

The Worker deployment must include `core-worker.js`, `browser-console.js` and
`browser-protocol.js` as ES modules, preserving its existing Durable Object and
TURN secret bindings. No namespace migration is required.

The browser URL origin is intentionally independent from the Android API origin.
Set optional `BROWSER_PUBLIC_ORIGIN` to a clean HTTPS origin such as
`https://remote.example.com` when the default `workers.dev` hostname is blocked
by an AI/browser network policy. The session-creation response returns that
validated origin to Android, which uses it only for the copied browser URL; host
signaling and the existing WebRTC engine remain unchanged. Invalid values fall
back to the request origin.
Declare both existing exports as `{"type":"durable-object","storage":"sqlite"}`
in upload metadata (`AarisSession` and `PairingDirectory`) and inherit the four
existing bindings with strict validation. Do not create replacement namespaces.
