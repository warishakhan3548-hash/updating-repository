# Pairing connection recovery — 1.9.11

The reported `Failed to connect … workers.dev/…:443` occurs while redeeming
the code, before approval, ICE negotiation or screen media. A successful server
health check does not prove that a particular phone's network can reach that
hostname. Version 1.9.11 fixes the single-route recovery gap.

## Comparison with the reported working build

The user identified `49b7465` (1.9.9 / versionCode 97) as working and `9d6de41`
(1.9.10 / versionCode 98) as failing. Git blob comparison confirms these files
are byte-for-byte identical between those two commits:

| Area | Identical files |
| --- | --- |
| Connect UI and code redemption | `MainActivity.kt`, `CloudflarePairingGateway.kt` |
| HTTPS origin, client settings and credentials | `CloudflareBackend.kt` |
| Signaling and controller connection owner | `CloudflareSignalingClient.kt`, `ControllerConnectionService.kt` |
| Permissions and signed-build configuration | `AndroidManifest.xml`, `codemagic.yaml` |
| Pairing/session/signaling/TURN authority | `cloudflare/core-worker.js` |

The Gradle difference is only versionCode/versionName; the dependencies and
SDK levels are unchanged. Rendering, capture and AI files do differ, but the
reported TCP connect failure is on the unchanged HTTP code-redemption path,
before controller WebRTC startup. These facts do not establish a video/AI
regression as the cause. They also cannot identify the phone's exact network
failure remotely. The targeted fix adds recovery when the first public route
is unreachable, retaining the existing media and consent logic.

## Execution and state map

| User step | Source owner | Backend / UI result |
| --- | --- | --- |
| Connect and submit 12 digits | `MainActivity.connect` → `CloudflarePairingGateway.redeemCode` | One controller token is generated for the redemption attempt |
| Reach the service | `CloudflareBackend` → `BackendTransport` | OkHttp fast fallback races available IP routes; an unreachable origin can use the second fixed origin |
| Redeem or retry | `aaris-remote-ice` → `PairingDirectory` → `AarisSession.redeem` | The same token recovers the same controller; another controller gets a conflict |
| Host approves | `AarisSession.transition` / controller foreground service | `HOST_APPROVED`; controller can prewarm TURN and signaling |
| Host allows screen capture | MediaProjection → `SCREEN_READY` | Offer, answer and ICE candidates cross either public route |
| Reconnect signaling | `CloudflareSignalingClient` → shared replay log | Working origin and replay cursor are retained; WebRTC media continues directly |

## Routes and retry limits

- Primary: `https://aaris-remote-ice.aaris-remote-wk3548.workers.dev`.
- Recovery: `https://aaris-remote-connect.pages.dev`.
- Pages binds `CORE` directly to the existing `aaris-remote-ice` Worker. There
  is no second pairing store, copied TURN secret or external HTTP hop back to
  `workers.dev`. Authentication, host approval and screen consent stay in the
  core Worker. WebSocket upgrade responses pass through intact.
- OkHttp 5.3.2 fast fallback starts alternate IP connection attempts after
  250 ms instead of waiting for each unreachable IP to time out. Each HTTP
  attempt has a 4-second connect and 12-second overall deadline. At most two
  origins are tried per request. The successful origin is reused in memory
  for session calls and signaling; a transport failure can switch it again.
- Code redemption retries use the same valid controller token. GET, state,
  close and ephemeral ICE requests can also recover from a lost response.
- New session creation and event publication use one-shot bodies. They may
  switch origins before request headers start, but are never automatically
  replayed after sending starts. Existing signaling negotiation IDs remain
  authoritative for application-level recovery.
- HTTP errors (including invalid/used codes and authorization failures),
  certificate errors, protocol errors and cancellation do not trigger an
  origin retry. Redirects are disabled so session credentials stay on the
  two configured origins. Exhausted network recovery reports a clear message
  instead of displaying an internal hostname and IP address.

## Deployment and verification

The recovery gateway is in `cloudflare/connect-gateway/_worker.js`; its Pages
configuration is `cloudflare/wrangler.connect.jsonc`. From `cloudflare`, deploy
with `npx wrangler pages deploy connect-gateway --project-name aaris-remote-connect`.
Both Pages environments must retain the `CORE` service binding. Core Worker
bindings and Durable Object namespaces must not change.

CI runs the gateway protocol tests, Android unit tests/lint/builds and
`python3 cloudflare/smoke-connect.py`. The live smoke creates synthetic sessions
in both route directions, tests stable-token redemption retry, competing-token
rejection, consent gates, prewarm TURN, cross-route WebSocket offer/answer/ICE,
cursor-based replay, LIVE and cleanup. It never prints pairing credentials.
Android transport regression tests also simulate a blackholed IP, an
unreachable primary origin and committed POSTs with lost responses.

These checks verify control-plane recovery. They do not measure video latency
on two physical phones or guarantee connectivity when both public routes are
blocked. Installing the 1.9.11 APK is required to use the new client route logic.
