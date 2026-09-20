# Aaris Pharmacy permanent Android signing

Production identity is intentionally kept outside Git.

## Immutable app identity

- Android application ID: `com.aaris.pharmacy`
- Permanent key alias: `upload`
- Expected signing certificate SHA-256:
  `33:0D:16:11:84:9C:7C:9B:1F:9F:59:2C:45:89:32:F2:5A:E6:F3:AB:A1:BC:7E:8A:BF:BC:9E:68:68:EF:00:4F`
- Codemagic signing reference: `aaris_permanent`

The private `.jks`, keystore password and key password must never be committed.

## Codemagic

Upload the owner's permanent JKS under:

Team settings -> Code signing identities -> Android keystores

Use reference name:

`aaris_permanent`

Use the keystore's real password, alias `upload`, and key password. Codemagic injects
`CM_KEYSTORE_PATH`, `CM_KEYSTORE_PASSWORD`, `CM_KEY_ALIAS`, and
`CM_KEY_PASSWORD` only on the build machine.

The workflow verifies the certificate fingerprint before producing any production
artifact, then builds both the website APK and Play-ready AAB.

## Local / Termux

Copy `android/key.properties.example` to `android/key.properties`, point
`storeFile` at the owner's permanent JKS and fill the passwords locally.
`android/key.properties`, `*.jks`, and `*.keystore` are ignored by Git.

A release task without Codemagic credentials or local key.properties fails closed.
Debug builds are unaffected.

## Version continuity

Codemagic uses `PROJECT_BUILD_NUMBER + 1000` as Android `versionCode` so
successive Codemagic builds remain upgradeable. Human-facing `versionName`
continues to come from `pubspec.yaml` and can be changed for releases.
