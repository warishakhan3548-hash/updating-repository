#!/usr/bin/env python3
"""Deprecated legacy Quran-audio vendoring entry point.

Aaris Quran no longer puts the full recitation corpus in the repository or base APK.
Pronunciation is delivered after installation as explicit user-requested Surah packs:
- Reader: Audio ↓ for one Surah
- Settings: Quran audio · Download All
- Installed Surahs replay locally/offline, including ambient recall overlays.

Keeping this file as a fail-fast tombstone prevents old Termux notes or copied commands from
accidentally starting the retired multi-hundred-megabyte repository-vendoring workflow.
"""

raise SystemExit(
    "Legacy Quran audio vendoring is disabled. "
    "Build/install the small base app, then use Audio ↓ per Surah or Quran audio · Download All in the app."
)
