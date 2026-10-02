# Cloudflare backend

Deployed Worker: `aaris-remote-ice`.

Aaris Remote 1.8 replaces the previous Firebase-authorized TURN-only Worker with a Cloudflare-native control plane.

Bindings:
- `SESSIONS` -> SQLite Durable Object class `AarisSession`
- `PAIRINGS` -> SQLite Durable Object class `PairingDirectory`
- `TURN_KEY_ID` -> secret text
- `TURN_KEY_SECRET` -> secret text

The Worker owns pairing, authoritative backend state, signaling replay, hibernatable WebSockets, and TURN credential minting. The Android application contains no Cloudflare account secret and no Firebase dependency.
