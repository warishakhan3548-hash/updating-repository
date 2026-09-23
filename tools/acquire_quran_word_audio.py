#!/usr/bin/env python3
"""Retired monolithic Quran word-audio acquisition entry point.

Aaris no longer downloads 77k clips into the app repository. The maintained architecture builds
114 immutable Surah .aqp containers from the pinned isolated-word dataset outside normal Android
builds, publishes those containers separately, and keeps only the tiny SHA-256 catalog in the APK.
"""

raise SystemExit(
    "Legacy repository-local Quran audio acquisition is retired. "
    "Use tools/build_word_audio_surah_packs.py in the reviewed one-time pack-release workflow."
)
