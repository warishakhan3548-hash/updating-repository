#!/usr/bin/env python3
"""Static guard for Aaris's offline-first runtime/build contract.

Quran text, Hadith, search, learning and recall must remain local and usable with no network.
The sole runtime network boundary is explicit user-requested Quran recitation download:
QuranAudioDownloadManager.java may fetch immutable per-Surah audio/timing files, which are then
validated and stored privately for local playback. Normal Gradle builds never acquire audio.
"""
import json
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
MANIFEST=ROOT/"app/src/main/AndroidManifest.xml"
APP_JAVA=ROOT/"app/src/main/java"
GRADLE=ROOT/"app/build.gradle"
AUDIO_DOWNLOADER=APP_JAVA/"com/aaris/quran/QuranAudioDownloadManager.java"
AUDIO_STORE=APP_JAVA/"com/aaris/quran/QuranAudioStore.java"
AUDIO_LOCK=ROOT/"source-vault/quran-audio/on-demand-source-lock.json"

NETWORK_IMPORTS=(
    "java.net.",
    "okhttp3.",
    "retrofit2.",
    "io.ktor.client.",
)
ALLOWED_BUILD_SCRIPTS={
    "tools/check_offline_contract.py",
    "tools/build_content.py",
    "tools/prepare_open_hadith_data.py",
    "tools/build_hadith.py",
}


def fail(message):
    raise SystemExit("OFFLINE CONTRACT FAILED: "+message)


def main():
    manifest=MANIFEST.read_text(encoding="utf-8")
    if 'android.permission.INTERNET' not in manifest:
        fail("on-demand Quran audio requires INTERNET permission")
    if manifest.count('android.permission.INTERNET')!=1:
        fail("INTERNET permission must be declared exactly once")

    offenders=[]
    for path in APP_JAVA.rglob("*.java"):
        text=path.read_text(encoding="utf-8")
        for prefix in NETWORK_IMPORTS:
            if re.search(r"^\s*import\s+"+re.escape(prefix),text,re.MULTILINE):
                if path.resolve()!=AUDIO_DOWNLOADER.resolve():
                    offenders.append(f"{path.relative_to(ROOT)} imports {prefix}*")
    if offenders:
        fail("; ".join(offenders))

    if not AUDIO_DOWNLOADER.is_file() or not AUDIO_STORE.is_file() or not AUDIO_LOCK.is_file():
        fail("on-demand Quran audio source/store/downloader wiring is incomplete")
    lock=json.loads(AUDIO_LOCK.read_text(encoding="utf-8"))
    if lock.get("schema")!=1 or lock.get("delivery")!="ON_DEMAND_SURAH_LOCAL_V1":
        fail("unsupported on-demand Quran audio source lock")
    downloader=AUDIO_DOWNLOADER.read_text(encoding="utf-8")
    store=AUDIO_STORE.read_text(encoding="utf-8")
    revision=str(lock.get("revision") or "")
    repo_id=str(lock.get("repo_id") or "")
    quran_hash=str(lock.get("canonical_quran_sqlite_sha256") or "")
    if len(revision)!=40 or revision not in store:
        fail("runtime audio source revision differs from reviewed lock")
    if repo_id not in downloader:
        fail("runtime audio repository differs from reviewed lock")
    if len(quran_hash)!=64 or quran_hash not in store:
        fail("runtime audio Quran binding differs from reviewed lock")
    if "HttpURLConnection" not in downloader:
        fail("audio downloader no longer has an explicit reviewed HTTPS boundary")
    if "http://" in downloader:
        fail("audio downloader contains cleartext HTTP")
    if "https://huggingface.co/datasets/" not in downloader:
        fail("audio downloader source is not the reviewed Hugging Face dataset")
    if "6875b35e45cc83107daf3ab7d3a8bd8b2baa51b3" not in downloader and "SOURCE_REVISION" not in downloader:
        fail("audio downloader is not pinned to the reviewed immutable source revision")

    # Playback/storage must never contain their own network fallback.
    for rel in (
        "com/aaris/quran/QuranAudioStore.java",
        "com/aaris/quran/WordAudioPlayer.java",
        "com/aaris/quran/AmbientRecallService.java",
    ):
        text=(APP_JAVA/rel).read_text(encoding="utf-8")
        if re.search(r"https?://|URLConnection|HttpURLConnection|java\.net\.",text):
            fail(f"{rel} contains a network path; only QuranAudioDownloadManager may download")

    gradle=GRADLE.read_text(encoding="utf-8")
    network_maintainer_scripts={
        *(p.name for p in (ROOT/"tools").glob("acquire_*.py")),
        "complete_quran_audio_pack.py",
    }
    for name in sorted(network_maintainer_scripts):
        if name in gradle:
            fail(f"normal Android build references one-time network maintainer script {name}")

    if "assets.srcDir activeQuranAudioSource" in gradle or "verifyQuranAudioPack" in gradle:
        fail("legacy monolithic Quran audio is still wired into the APK build")

    # Every Python script invoked by the Android build must be an explicitly reviewed offline tool.
    invoked=set(re.findall(r"['\"](tools/[A-Za-z0-9_.-]+\.py)['\"]",gradle))
    unexpected=invoked-ALLOWED_BUILD_SCRIPTS
    if unexpected:
        fail("unreviewed Python build scripts: "+", ".join(sorted(unexpected)))

    print("PASS: Quran/Hadith/search stay offline; network is isolated to explicit immutable Surah-audio downloads")


if __name__=="__main__":
    main()
