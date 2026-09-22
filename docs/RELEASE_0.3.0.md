# Release APK 0.3.0 — 22 September 2026

Built from clean source commit `b12c7a252079cd6641af6cb7b1510a75642244c8`, tree
`6d3ab2d9c6c198ecc9b20b31c31c62899e1d0307`, using the official SDK release builder.

| Property | Value |
| --- | --- |
| Artifact | Aaris-Quran-0.3.0-release.apk |
| Application ID | com.aaris.quran |
| Version code / name | 3 / 0.3.0 |
| Minimum / target API | 26 / 35 |
| Size | 6,702,130 bytes |
| APK SHA-256 | `474743d483889b5dc21ed24fed1ea365220eac7ad7ff0e31587524e14d15940f` |
| Signer certificate SHA-256 | `07774fadc74181411fa5f39e9c525b0b7e47838252c166e02805bb963bd81b1b` |
| Quran pack SHA-256 | `521fdc94f176d3e73e2889a8a4af07259731d289491c08ed1cda9b3f302ab8b1` |

The certificate matches release 0.2.0. No signing secrets are checked in. An actual
on-device update/install test has not been performed. The APK and public `.build.json`
verification report are delivered separately. No AAB or CI workflow was produced.

## Changes

- Revised teal/blue/gold glass surfaces, readable secondary text, Arabic chapter layout,
  verse spacing, touch feedback and explicit primary actions.
- Four visible tabs: Aaj, Quran, Hadith and Yaad.
- User-started native recall overlay with a 1–120-minute timer, source-backed selection,
  optional due-only practice, a real 10-second test, close/reveal/self-rating and stop controls.
  The single timer continues across external app switches and pauses on lock or inside Aaris.
- Six Hadith collection links and Sunnah.com search are visible in their own tab. They open
  an external browser and require internet. **No offline Hadith corpus is bundled.**

## Verified

- 113 core behavioral checks, including 19 ambient timer/selection checks.
- 6,236 exact source coordinates and safe-token mappings; 6,122 consecutive ayah transitions;
  77,881 original word ranges; 13 positive retrieval cases and 20 engineered absent queries.
- Android API 35 Java compilation, resources, startup/service manifest and permission wiring.
- Release v2/v3 signature, zip alignment, non-debuggable package flags, version/API metadata,
  ZIP CRC, DEX SHA-1/Adler checksums and presence of new overlay service/core classes.
- Embedded Quran pack hash matches the unchanged source archive.
- Final artifact permissions are exactly SYSTEM_ALERT_WINDOW, FOREGROUND_SERVICE,
  FOREGROUND_SERVICE_SPECIAL_USE and POST_NOTIFICATIONS.

## Runtime limits

No emulator/physical-phone launch, overlay delivery, RTL screenshot, accessibility, OEM battery,
real update/install, PDF rendering or Android document-provider integration test was possible
in this environment. Passing compilation and timer tests does not establish these outcomes.
Use the acceptance scenarios in [AMBIENT_RECALL.md](AMBIENT_RECALL.md) on the actual device.

Android draw-over-apps permission is required. The optional notification permission controls
notification-drawer visibility. OEM service termination and applications suppressing overlays
can prevent delivery. A stopped/killed session must be restarted explicitly in Yaad.
The remaining architecture/content gaps remain in [ARCHITECTURE_STATUS.md](ARCHITECTURE_STATUS.md).
