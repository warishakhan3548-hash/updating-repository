# Release signing

Aaris Quran release builds use the same permanent upload keystore for both APK and AAB outputs.

## Locked signing identity

- Drive backup filename: `Aarish-upload-keystore.jks`
- Keystore format: JKS
- Alias: `upload`
- Original keystore SHA-256: `96e1b2a8fa064f24155b9a8d615f20f2271ef723e6b0bef044d372b93729c8c0`
- Signing certificate SHA-256: `33:0D:16:11:84:9C:7C:9B:1F:9F:59:2C:45:89:32:F2:5A:E6:F3:AB:A1:BC:7E:8A:BF:BC:9E:68:68:EF:00:4F`
- Certificate validity: 2026-08-28 through 2054-01-13

The Gradle release path verifies the certificate fingerprint before a configured signed release is packaged. This prevents a different keystore from silently creating an incompatible future update.

Never commit the keystore or passwords. The repository ignores `*.jks`, `*.keystore`, `*.p12`, and `keystore.properties`.

## Local signed APK + AAB

Copy the Drive backup to a private local path, then copy `keystore.properties.example` to `keystore.properties` and fill in only the private values:

```properties
AARIS_KEYSTORE_PATH=/absolute/path/to/Aarish-upload-keystore.jks
AARIS_KEYSTORE_PASSWORD=your-private-store-password
AARIS_KEY_ALIAS=upload
# Only set this when the key password differs from the store password.
# AARIS_KEY_PASSWORD=your-private-key-password
```

Build both signed packages:

```sh
./gradlew --no-daemon --stacktrace \
  :app:assembleRelease \
  :app:bundleRelease \
  -PrequireReleaseSigning=true
```

Outputs:

- APK: `app/build/outputs/apk/release/app-release.apk`
- AAB: `app/build/outputs/bundle/release/app-release.aab`

The `requireReleaseSigning` guard makes the command fail instead of quietly producing an unsigned release when signing inputs are missing.

## GitHub Actions

The manual workflow `.github/workflows/release-build.yml` builds and verifies both signed outputs. Add these repository Actions secrets once:

- `AARIS_KEYSTORE_BASE64` — base64 of the exact private `Aarish-upload-keystore.jks` file.
- `AARIS_KEYSTORE_PASSWORD` — the keystore password.
- `AARIS_KEY_PASSWORD` — optional; only needed when the private-key password differs from the keystore password.

Do not put the base64 value, password, or keystore file in source control. After the secrets exist, run **Build signed release APK and AAB** from the Actions tab. The workflow verifies the APK signature, verifies the AAB JAR signature, writes SHA-256 checksums, and uploads both packages as one workflow artifact.

## Future Play Store updates

For every later release:

1. Keep `applicationId 'com.aaris.quran'` unchanged.
2. Increase `versionCode` in `app/build.gradle`; never reuse an already published version code.
3. Keep using this same signing identity.
4. Build with `-PrequireReleaseSigning=true` or the signed-release workflow.
5. Verify the certificate fingerprint still matches the locked value above before publishing.

The signing certificate, not the filename, is the durable update identity. A renamed copy of the same keystore is acceptable; a different certificate is not.
