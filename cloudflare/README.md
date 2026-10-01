# Aaris Remote ICE credential worker

This Worker is the server-side credential broker used by the Android client
before WebRTC signaling starts.

Security properties:

- The long-lived Cloudflare TURN key stays only in Worker secrets.
- The client sends its Firebase ID token and the current session UUID.
- The Worker verifies the Firebase token for project `aaris-control`.
- The Worker re-checks the RTDB session and issues credentials only to the
  recorded host/controller while the session is `SCREEN_READY` or `LIVE`.
- The response contains short-lived Cloudflare TURN credentials and is marked
  `Cache-Control: no-store`.
- The Android app keeps provider-diverse STUN as a fallback if the Worker is
  temporarily unavailable.

Runtime secrets:

- `TURN_KEY_ID`
- `TURN_KEY_SECRET`

Production route currently used by the app:

`https://aaris-remote-ice.aaris-remote-wk3548.workers.dev/v1/ice`

Do not commit the TURN key secret or generated TURN credentials.
