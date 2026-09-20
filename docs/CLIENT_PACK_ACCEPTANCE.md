# Client Content-Pack Acceptance State

This layer closes the client-side rollback gap without adding a network updater.

## Scope

Only release-approved packs participate. Debug/candidate packs do not create or advance acceptance state.

For each pack ID, the Android client persists:

- highest accepted signed `release_sequence`;
- SHA-256 of the exact approved manifest bundled into the application;
- SHA-256 of the exact runtime content artifact.

The state lives under `Context.noBackupFilesDir/security/content-pack-acceptance/`, separate from `user.sqlite`. It is intentionally not part of user learning-history export/import because restoring an older security-state snapshot could re-enable a rollback.

Android `AtomicFile` is used so a state update is written, synced and committed atomically. Access is serialized inside the store; the current app is single-process.

## Acceptance rules

Given the previously accepted record for a pack:

1. no previous record → accept the first approved release;
2. higher signed sequence → accept and atomically persist it;
3. same sequence + same manifest/content hashes → accept idempotently;
4. lower sequence → reject as rollback;
5. same sequence + different manifest or content hash → reject as equivocation/conflicting release identity.

The reader records acceptance only after the bundled runtime SQLite bytes have passed SHA-256 verification and activation.

## Trust boundary

This store does not verify Ed25519 signatures itself. Release builds already fail closed through the repository pack gate, which verifies the approved manifest and signed sequence against the project-controlled trust root. The Android acceptance store consumes only that build-approved identity.

A future downloaded-pack updater must perform equivalent on-device signature/trust verification **before** calling this acceptance store. It must not treat sequence persistence as a substitute for authenticity.

## Deliberate limitations

- no remote update channel is enabled;
- no freshness/expiry protocol is implemented yet;
- uninstalling/clearing app data removes local acceptance history, so a fresh installation starts from the trust material bundled with that APK;
- this mechanism does not defend a rooted/fully compromised device from local state tampering;
- explicit recovery/downgrade policy remains future work and must never silently lower the accepted sequence.

These limits are intentional. The current change provides monotonic client memory without pretending to be a full TUF implementation.
