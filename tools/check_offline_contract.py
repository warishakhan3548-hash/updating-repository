#!/usr/bin/env python3
"""Static guard for Aaris's offline-first Android/build contract.

Acquisition helpers may use the network when run explicitly by a maintainer. Android runtime and
normal Gradle content preparation may not. This check is deliberately small and deterministic so
future refactors cannot silently turn an offline pack into a website dependency.
"""
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
MANIFEST=ROOT/"app/src/main/AndroidManifest.xml"
APP_JAVA=ROOT/"app/src/main/java"
GRADLE=ROOT/"app/build.gradle"

BANNED_RUNTIME_IMPORTS=(
    "java.net.",
    "okhttp3.",
    "retrofit2.",
    "io.ktor.client.",
)
ALLOWED_BUILD_SCRIPTS={
    "tools/check_offline_contract.py",
    "tools/build_content.py",
    "tools/check_quran_audio.py",
    "tools/prepare_open_hadith_data.py",
    "tools/build_hadith.py",
}


def fail(message):
    raise SystemExit("OFFLINE CONTRACT FAILED: "+message)


def main():
    manifest=MANIFEST.read_text(encoding="utf-8")
    if 'android.permission.INTERNET' in manifest:
        fail("Android runtime declares INTERNET permission")

    offenders=[]
    for path in APP_JAVA.rglob("*.java"):
        text=path.read_text(encoding="utf-8")
        for prefix in BANNED_RUNTIME_IMPORTS:
            if re.search(r"^\s*import\s+"+re.escape(prefix),text,re.MULTILINE):
                offenders.append(f"{path.relative_to(ROOT)} imports {prefix}*")
    if offenders:
        fail("; ".join(offenders))

    gradle=GRADLE.read_text(encoding="utf-8")
    acquisition_names={
        p.name for p in (ROOT/"tools").glob("acquire_*.py")
    }
    for name in sorted(acquisition_names):
        if name in gradle:
            fail(f"normal Android build references one-time acquisition helper {name}")

    # Every Python script invoked by the Android build must be an explicitly reviewed offline tool.
    invoked=set(re.findall(r"['\"](tools/[A-Za-z0-9_.-]+\.py)['\"]",gradle))
    unexpected=invoked-ALLOWED_BUILD_SCRIPTS
    if unexpected:
        fail("unreviewed Python build scripts: "+", ".join(sorted(unexpected)))

    audio_store=(APP_JAVA/"com/aaris/quran/QuranAudioStore.java").read_text(encoding="utf-8")
    player=(APP_JAVA/"com/aaris/quran/WordAudioPlayer.java").read_text(encoding="utf-8")
    for name,text in (("QuranAudioStore.java",audio_store),("WordAudioPlayer.java",player)):
        if re.search(r"https?://|URLConnection|HttpURLConnection|Socket\s*\(",text):
            fail(f"{name} contains a network fallback")

    print("PASS: Android runtime and normal Gradle content build remain network-independent")


if __name__=="__main__":
    main()
