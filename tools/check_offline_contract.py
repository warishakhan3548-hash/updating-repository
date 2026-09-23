#!/usr/bin/env python3
"""Static guard for Aaris's offline-first isolated-word Quran pronunciation contract.

Quran text, Hadith, search, learning and recall remain local. Runtime network access is allowed only
after an explicit user audio-download action. Pronunciation itself must use complete isolated word
clips; timestamp slicing of a full-Surah recording is forbidden.
"""
import json
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
MANIFEST=ROOT/"app/src/main/AndroidManifest.xml"
APP_JAVA=ROOT/"app/src/main/java"
ASSETS=ROOT/"app/src/main/assets"
GRADLE=ROOT/"app/build.gradle"
AUDIO_DOWNLOADER=APP_JAVA/"com/aaris/quran/QuranAudioDownloadManager.java"
AUDIO_STORE=APP_JAVA/"com/aaris/quran/QuranAudioStore.java"
AUDIO_PLAYER=APP_JAVA/"com/aaris/quran/WordAudioPlayer.java"
AUDIO_LOCK=ROOT/"source-vault/quran-audio/on-demand-source-lock.json"
AUDIO_CATALOG=ASSETS/"quran-audio-word-catalog.json"

NETWORK_IMPORTS=("java.net.","okhttp3.","retrofit2.","io.ktor.client.")
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
    if manifest.count("android.permission.INTERNET")!=1:
        fail("on-demand pronunciation requires exactly one INTERNET permission")

    offenders=[]
    for path in APP_JAVA.rglob("*.java"):
        text=path.read_text(encoding="utf-8")
        for prefix in NETWORK_IMPORTS:
            if re.search(r"^\s*import\s+"+re.escape(prefix),text,re.MULTILINE):
                if path.resolve()!=AUDIO_DOWNLOADER.resolve():
                    offenders.append(f"{path.relative_to(ROOT)} imports {prefix}*")
    if offenders:
        fail("; ".join(offenders))

    if not AUDIO_DOWNLOADER.is_file() or not AUDIO_STORE.is_file() or not AUDIO_PLAYER.is_file() or not AUDIO_LOCK.is_file():
        fail("isolated-word Quran pronunciation wiring is incomplete")
    lock=json.loads(AUDIO_LOCK.read_text(encoding="utf-8"))
    if lock.get("schema")!=2 or lock.get("delivery")!="ISOLATED_WORD_SURAH_CONTAINER_V1":
        fail("unsupported isolated-word audio source lock")
    if lock.get("repo_id")!="zaibihassan/Quranic-Word-By-Word-Audio-Data":
        fail("isolated-word source repository changed")
    if lock.get("style")!="muallim" or lock.get("extension")!="opus":
        fail("isolated-word pronunciation style/format changed")
    if lock.get("download_policy")!="EXPLICIT_USER_ACTION_ONLY":
        fail("Quran pronunciation may only download after explicit user action")
    if lock.get("resume_policy")!="REVISION_SCOPED_PARTIAL_HTTP_RANGE":
        fail("Quran pronunciation resume policy is not revision-scoped")
    if lock.get("playback_policy")!="COMPLETE_ISOLATED_CLIP_FROM_ZERO_TO_NATURAL_COMPLETION":
        fail("Quran pronunciation playback policy no longer requires complete isolated clips")
    if lock.get("apk_policy")!="NO_QURAN_AUDIO_BYTES_IN_BASE_APK":
        fail("Quran pronunciation APK policy changed")
    if int(lock.get("canonical_quran_audio_words") or 0)!=77326:
        fail("canonical isolated-word count changed")

    downloader=AUDIO_DOWNLOADER.read_text(encoding="utf-8")
    store=AUDIO_STORE.read_text(encoding="utf-8")
    player=AUDIO_PLAYER.read_text(encoding="utf-8")
    revision=str(lock.get("revision") or "")
    alignment=str(lock.get("canonical_quran_alignment_sha256") or "")
    if len(revision)!=40 or revision not in store:
        fail("runtime isolated-word source revision differs from reviewed lock")
    if len(alignment)!=64 or alignment not in store:
        fail("runtime pronunciation Quran alignment differs from reviewed lock")
    if lock.get("repo_id") not in store:
        fail("runtime pronunciation source identity differs from reviewed lock")
    if "AARISQW1" not in store or "ISOLATED_WORD_SURAH_CONTAINER_V1" not in store:
        fail("runtime isolated-word container parser is missing")
    if "HttpURLConnection" not in downloader:
        fail("audio downloader no longer has the reviewed HTTPS boundary")
    if 'setRequestProperty("Range","bytes="+existing+"-")' not in downloader:
        fail("audio downloader lost resumable HTTP Range support")
    if '".partial-"+SOURCE_REVISION.substring(0,12)' not in store:
        fail("partial audio is no longer scoped to the immutable source revision")
    if 'REPO="warishakhan3548-hash/updating-repository"' not in downloader:
        fail("runtime pack host repository changed")

    # This is the core pronunciation rule: never seek into a continuous recitation and never stop
    # it on a guessed timestamp. Each MediaPlayer data source must already be one complete word clip.
    forbidden_player_tokens=("seekTo(","SEEK_CLOSEST","startMs","endMs","postDelayed(")
    found=[token for token in forbidden_player_tokens if token in player]
    if found:
        fail("timestamp/full-Surah word slicing returned: "+", ".join(found))
    if "setDataSource(opened.getFD(),clip.offset,clip.length)" not in player:
        fail("player no longer addresses one complete isolated clip by byte range")

    # Playback/storage must never contain a network fallback.
    for rel in (
        "com/aaris/quran/QuranAudioStore.java",
        "com/aaris/quran/WordAudioPlayer.java",
        "com/aaris/quran/AmbientRecallService.java",
    ):
        text=(APP_JAVA/rel).read_text(encoding="utf-8")
        # Catalog provenance/download URLs may be stored as inert strings. These classes must not
        # have any networking capability; only QuranAudioDownloadManager may open a connection.
        if re.search(r"URLConnection|HttpURLConnection|java\.net\.",text):
            fail(f"{rel} contains network-capable code; only QuranAudioDownloadManager may download")

    content_store=(APP_JAVA/"com/aaris/quran/ContentStore.java").read_text(encoding="utf-8")
    quran_app=(APP_JAVA/"com/aaris/quran/QuranApp.java").read_text(encoding="utf-8")
    if "audio_alignment_sha256" not in content_store or "audioAlignmentHash" not in quran_app:
        fail("runtime pronunciation is not bound to stable semantic Quran word identity")

    # Catalog is tiny metadata only. Every public URL/hash must be fixed before release.
    if not AUDIO_CATALOG.is_file():
        fail("isolated-word Surah catalog is missing from base assets")
    catalog=json.loads(AUDIO_CATALOG.read_text(encoding="utf-8"))
    if (catalog.get("schema")!=1 or catalog.get("delivery")!="ISOLATED_WORD_SURAH_CONTAINER_V1" or
        catalog.get("source_revision")!=revision or
        catalog.get("canonical_quran_alignment_sha256")!=alignment or
        int(catalog.get("canonical_quran_audio_words") or 0)!=77326 or
        int(catalog.get("surahs") or 0)!=114):
        fail("isolated-word Surah catalog binding is invalid")
    packs=catalog.get("packs")
    if not isinstance(packs,dict) or len(packs)!=114:
        fail("isolated-word Surah catalog must contain exactly 114 packs")
    words=0
    for s in range(1,115):
        key=f"{s:03d}";meta=packs.get(key)
        if not isinstance(meta,dict):
            fail(f"missing Surah pack metadata: {key}")
        url=str(meta.get("url") or "")
        sha=str(meta.get("sha256") or "")
        count=int(meta.get("words") or 0);size=int(meta.get("bytes") or 0)
        if (not url.startswith("https://github.com/warishakhan3548-hash/updating-repository/releases/download/") or
            not url.endswith(f"/{key}.aqp") or len(sha)!=64 or count<1 or size<64):
            fail(f"invalid immutable Surah pack metadata: {key}")
        words+=count
    if words!=77326:
        fail("catalog Surah word totals do not equal canonical pronunciation coverage")

    # No actual pronunciation bytes may ever enter the base APK.
    binary_suffixes={".aqp",".opus",".pb",".pack"}
    accidental=[p for p in ASSETS.rglob("*") if p.is_file() and p.suffix.lower() in binary_suffixes]
    if accidental:
        fail("Quran pronunciation binary found in APK assets: "+", ".join(str(p.relative_to(ROOT)) for p in accidental))

    gradle=GRADLE.read_text(encoding="utf-8")
    network_maintainer_scripts={
        *(p.name for p in (ROOT/"tools").glob("acquire_*.py")),
        "complete_quran_audio_pack.py",
        "build_word_audio_surah_packs.py",
    }
    for name in sorted(network_maintainer_scripts):
        if name in gradle:
            fail(f"normal Android build references maintainer acquisition/packing tool {name}")
    if "assets.srcDir activeQuranAudioSource" in gradle or "verifyQuranAudioPack" in gradle:
        fail("legacy monolithic Quran audio is still wired into the APK build")

    invoked=set(re.findall(r"['\"](tools/[A-Za-z0-9_.-]+\.py)['\"]",gradle))
    unexpected=invoked-ALLOWED_BUILD_SCRIPTS
    if unexpected:
        fail("unreviewed Python build scripts: "+", ".join(sorted(unexpected)))

    print("PASS: complete isolated Quran word clips only; base content stays offline and audio binaries stay out of the APK")


if __name__=="__main__":
    main()
