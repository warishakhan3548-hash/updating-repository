# Signing and building Aaris Remote without Codemagic

This repository includes a **manual GitHub Actions** workflow named **Signed Android Release**. It builds an installable `app-release.apk` on GitHub-hosted Ubuntu without waiting for Codemagic. GitHub Actions may still have its own runner queue.

## Initial setup (repository administrator)

1. Go to **Settings → Secrets and variables → Actions → New repository secret** on GitHub.
2. Store **three repository secrets** (never commit them or paste them into issues/PRs):
   - `AARIS_UPLOAD_KEYSTORE_BASE64`: the **base64 text of the complete original JKS file** (not its filename or a path).
   - `AARIS_UPLOAD_STORE_PASSWORD`: the JKS keystore password.
   - `AARIS_UPLOAD_KEY_PASSWORD`: the private-key password for alias `upload`.
3. Encode your **local** keystore file, for example on Linux/macOS:
   ```bash
   base64 < "/path/to/Aarish-upload-keystore.jks" | tr -d '\n'
   ```
   Windows PowerShell:
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\\path\\to\\Aarish-upload-keystore.jks"))
   ```
   Copy only the output into the GitHub secret form, not a repository file. Because base64 is **not encryption**, treat it as sensitively as the keystore itself.
4. Retain an offline, encrypted backup of the original keystore and passwords. Losing a signing key can prevent future updates depending on distribution/App Signing setup.

## Build the APK

1. Merge the workflow onto `main`.
2. Go to **Actions → Signed Android Release → Run workflow**, select **main** and run.
3. Once the workflow succeeds, open that run's **Artifacts → AarisRemote-signed-release**.
4. Download `AarisRemote-<version>-signed-release.apk` and its SHA-256 checksum.

The workflow runs `assembleRelease` with `-PrequireReleaseSigning=true` and fails instead of uploading an unsigned APK. It checks the keystore alias and pinned release certificate SHA-256, verifies APK Signature Scheme v2 or v3, ZIP alignment, package name, and then checks the final artifact. Tests and lint remain part of the standard Android CI workflow.

## Important

- No private key, password, or base64 signing material belongs in any Git commit, workflow YAML, Codemagic configuration, issue, or PR comment.
- The existing Codemagic configuration may still be used, but this GitHub Actions path does **not** require Codemagic.
- Signing with the correct upload key **does not** guarantee an upgrade over a previous installed APK signed by a different key; compare the installed app's signing certificate and ensure the new version code is greater.
- Use the same signing identity for future APK updates.
