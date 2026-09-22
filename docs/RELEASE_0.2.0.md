# Aaris Quran 0.2.0 release audit

Built 22 September 2026 from the clean source commit
`95dbb29ede564df74a49d900d57610511af3f7bf`.

| Item | Result |
| --- | --- |
| File | `Aaris-Quran-0.2.0-release.apk` |
| Size | 6,685,661 bytes |
| Package | `com.aaris.quran` |
| Version | 0.2.0 / code 2 |
| Android | Minimum API 26 (Android 8), target API 35 |
| Build | Release; debuggable false; no AAB |
| Signing | Dedicated RSA-3072 release key; APK v2/v3 verification passed |
| Alignment | Official zipalign verification passed |
| Runtime code | D8 release compilation; DEX SHA-1/Adler checksums and application entry points checked |
| Permissions | No declared permissions; no runtime network dependency or system overlay service |
| Content | 114 surahs, 6,236 ayahs, 77,881 word ranges |
| Hadith | Zero records; the six collections are not installed |

APK SHA-256:
`effef175eaf394903996851b9eb12aa9493388d87155b428cb44214bcbf1a8ba`

Public signing-certificate SHA-256:
`07774fadc74181411fa5f39e9c525b0b7e47838252c166e02805bb963bd81b1b`

Embedded Quran-pack SHA-256:
`521fdc94f176d3e73e2889a8a4af07259731d289491c08ed1cda9b3f302ab8b1`

## Fixes and verification

- File-picker export survives Activity recreation through a checksum-bound private disk handoff.
  Cancelled exports clean up only their own payload; missing pickers and duplicate requests are handled.
- Reader settings apply when the settings sheet is closed, including Back/close controls. Returning
  to the reader hides the search keyboard. Sheets dismiss the meaning ribbon and account for system
  navigation/cutout insets. Destroyed activities do not rebuild their UI on late callbacks.
- 94 core regressions passed, including failed export destination, corrupted payload and recreated
  store recovery. All 6,236 coordinate/token mappings and 6,122 within-surah transition excerpts pass.
- Positive, absent-query and mixed-source quotation/negation search cases passed. Native Java and
  resources compile. The packaged SQLite hash matches the verified content manifest exactly.
- Standard Gradle release resolution failed because AGP was unavailable from this environment's
  configured repositories. The dependency-free app was built with the installed official SDK's
  aapt2, javac, D8, zipalign and apksigner instead. The script is checked in and refuses unhandled
  dependency changes. It does not inject a runtime wrapper or change the source corpus.

## Scope still requiring Android device checks

No Android emulator, attached phone or KVM device was available. Actual installation/launch,
Arabic shaping/word taps, ribbon positioning, large-font/rotation behavior, and Android PDF and
document-provider round trips have not been observed on a device. Signature/package checks are
not a substitute for those runtime checks.

The glass surfaces are native static translucent gradients; no claim of tested live GPU blur.
The meaning ribbon stays inside the app. An overlay over other applications is not implemented.
Bukhari, Muslim, Abu Dawud, Tirmidhi, Nasai and Ibn Majah are not bundled. Reviewed morphology,
full FSRS, audio and signed content updates remain listed in the architecture status document.

The APK and its public build report were delivered separately. The private signing-key recovery
archive was also delivered privately; neither its key nor its password is stored in git. Future
APK updates must reuse that signing key to preserve Android's application update identity.
