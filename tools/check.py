#!/usr/bin/env python3
"""Offline integrity + JVM regression checks; optionally compile Android sources.

Usage: python3 tools/check.py [--android-jar /path/to/platform/android.jar]
No APK, CI workflow, emulator or downloaded testing dependency is required.
"""
import argparse
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import sys
import xml.etree.ElementTree as ET
from acquire_sunnah_api import body_text
from build_hadith import search_text as hadith_search_text

ROOT = Path(__file__).resolve().parents[1]


def main():
    if not __debug__:
        raise SystemExit('Run checks without -O; integrity assertions must be enabled.')
    assert body_text('<p>نَصٌّ <b>تَجْرِيبِيٌّ</b></p><p>أَخْبَارٌ &amp; آثار</p>') == 'نَصٌّ تَجْرِيبِيٌّ\nأَخْبَارٌ & آثار'
    assert body_text('نَصٌّ تَجْرِيبِيٌّ') == 'نَصٌّ تَجْرِيبِيٌّ'
    parser = argparse.ArgumentParser()
    parser.add_argument('--android-jar', type=Path)
    parser.add_argument('--aapt2', type=Path, help='Optional Android resource compiler (requires --android-jar)')
    args = parser.parse_args()
    if args.aapt2 and not args.android_jar:
        parser.error('--aapt2 requires --android-jar')

    # The manual verification path must enforce the same no-network contract as Gradle.
    subprocess.run([
        sys.executable, str(ROOT / 'tools/check_offline_contract.py')
    ], check=True, cwd=ROOT)
    java = shutil.which('java')
    if not java and os.environ.get('JAVA_HOME'):
        java = str(Path(os.environ['JAVA_HOME']) / 'bin/java')
    if not java:
        raise SystemExit('A Java 17+ runtime containing jdk.compiler is required.')
    wrapper_properties = (ROOT / 'gradle/wrapper/gradle-wrapper.properties').read_text(encoding='utf-8')
    assert 'distributionUrl=https\\://services.gradle.org/distributions/gradle-8.11.1-bin.zip' in wrapper_properties
    assert 'distributionSha256Sum=f397b287023acdba1e9f6fc5ea72d22dd63669d59ed4a289a29b1a76eee151c6' in wrapper_properties, 'Gradle distribution must remain pinned to the reviewed official SHA-256'
    wrapper_jar = ROOT / 'gradle/wrapper/gradle-wrapper.jar'
    assert hashlib.sha256(wrapper_jar.read_bytes()).hexdigest() == '2db75c40782f5e8ba1fc278a5574bab070adccb2d21ca5a6e5ed840888448046', 'Checked-in Gradle wrapper JAR must match the official Gradle 8.11.1 checksum'
    workflow_text = (ROOT / '.github/workflows/verify-offline-translations.yml').read_text(encoding='utf-8')
    assert 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' in workflow_text, 'Checkout action must stay pinned to the reviewed immutable v4 revision'
    assert 'actions/setup-java@b6effb05e454b25005698d916606bdc6ffcbf961' in workflow_text, 'Java setup action must stay pinned to the reviewed immutable v5 revision'
    for android_task in (':core:lint', ':app:assembleDebug', ':app:lintDebug', ':app:assembleRelease', ':app:lintRelease', ':app:bundleRelease'):
        assert android_task in workflow_text, f'Standard CI must exercise {android_task}'
    root_build_text = (ROOT / 'build.gradle').read_text(encoding='utf-8')
    core_build_text = (ROOT / 'core/build.gradle').read_text(encoding='utf-8')
    quran_text_source = (ROOT / 'app/src/main/java/com/aaris/quran/QuranText.java').read_text(encoding='utf-8')
    assert "id 'com.android.lint' version '8.9.2' apply false" in root_build_text, 'Core lint must stay pinned to the reviewed Android plugin version'
    assert "id 'com.android.lint'" in core_build_text, 'Core search/evidence sources must not be excluded from lint'
    assert 'android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE' not in quran_text_source and 'Layout.BREAK_STRATEGY_SIMPLE' in quran_text_source, 'Quran text wrapping must remain compatible with minSdk 26'
    assert workflow_text.count('./gradlew --no-daemon --no-parallel') >= 3 and '--max-workers=1' in workflow_text, 'Large offline assets must package in isolated bounded-memory Gradle phases'
    assert workflow_text.count("- '.github/workflows/release-build.yml'") == 2, 'Signed release workflow changes must trigger standard CI on push and pull_request'
    push_header = workflow_text.split('pull_request:',1)[0]
    assert '      - main\n' in push_header, 'Relevant merges to main must receive a post-merge verification run'
    release_workflow_text = (ROOT / '.github/workflows/release-build.yml').read_text(encoding='utf-8')
    assert 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' in release_workflow_text, 'Signed release checkout must stay pinned'
    assert 'actions/setup-java@b6effb05e454b25005698d916606bdc6ffcbf961' in release_workflow_text, 'Signed release Java setup must stay pinned'
    assert 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' in release_workflow_text, 'Signed release artifact upload must stay pinned'
    assert release_workflow_text.count('-PrequireReleaseSigning=true') >= 2, 'Every publishable APK/AAB Gradle phase must require signing'
    assert ':app:assembleRelease -PrequireReleaseSigning=true' in release_workflow_text and ':app:bundleRelease -PrequireReleaseSigning=true' in release_workflow_text, 'Publishable CI must build both signed APK and signed AAB'
    assert release_workflow_text.count('./gradlew --no-daemon --no-parallel') >= 2 and '--max-workers=1' in release_workflow_text, 'Signed APK/AAB packaging must stay in isolated bounded-memory Gradle phases'
    assert 'secrets.AARIS_KEYSTORE_BASE64' in release_workflow_text and 'secrets.AARIS_KEYSTORE_PASSWORD' in release_workflow_text, 'Signed release workflow must source private signing material only from repository secrets'
    assert 'apksigner" verify --verbose --print-certs' in release_workflow_text and 'jarsigner -verify' in release_workflow_text, 'Signed release workflow must verify both APK and AAB signatures'
    capture_workflow_text = (ROOT / '.github/workflows/capture-hadeethenc.yml').read_text(encoding='utf-8')
    assert 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' in capture_workflow_text, 'HadeethEnc capture workflow checkout must stay pinned to the reviewed immutable v4 revision'
    release_builder_text = (ROOT / 'tools/build_release.py').read_text(encoding='utf-8')
    assert "expanded = value.replace('${applicationId}', app_id)" in release_builder_text, 'Non-Gradle release builder must expand applicationId manifest placeholders'
    assert "if '${' in expanded:" in release_builder_text, 'Non-Gradle release builder must reject unknown manifest placeholders instead of packaging them literally'
    for build_control in ("- 'build.gradle'", "- 'settings.gradle'", "- 'gradle.properties'", "- 'gradlew'", "- 'gradlew.bat'", "- 'gradle/wrapper/**'"):
        assert workflow_text.count(build_control) == 2, f'CI path filters must cover {build_control} on push and pull_request'
    assets = ROOT / 'app/src/main/assets'
    manifest = json.loads((assets / 'content-manifest.json').read_text())
    pack = assets / 'quran.sqlite'
    assert hashlib.sha256(pack.read_bytes()).hexdigest() == manifest['sqlite_sha256']
    db = sqlite3.connect(f'file:{pack}?mode=ro', uri=True)
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    assert db.execute('SELECT count(*) FROM ayah').fetchone()[0] == 6236
    assert db.execute('SELECT count(*) FROM surah').fetchone()[0] == 114
    assert db.execute('SELECT count(*) FROM word').fetchone()[0] == manifest['words']
    for text, digest in db.execute('SELECT arabic,sha256 FROM ayah'):
        assert hashlib.sha256(text.encode()).hexdigest() == digest
    for text, start, end, word in db.execute(
            'SELECT a.arabic,w.start_cp,w.end_cp,w.arabic FROM word w JOIN ayah a ON a.id=w.ayah_id'):
        assert text[start:end] == word, 'Word/source offset mismatch'
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
    audio_alignment=hashlib.sha256()
    audio_words=0
    for wid,aid,position,word_arabic in db.execute(
            "SELECT id,ayah_id,position,arabic FROM word "
            "WHERE position>0 AND id LIKE '%:W:%' AND mapping_state='SOURCE_ALIGNED' ORDER BY id"):
        audio_alignment.update(f"{wid}\\t{aid}\\t{position}\\t{word_arabic}\\n".encode('utf-8'))
        audio_words += 1
    assert audio_words == 77326, 'Canonical Quran audio word count changed'
    assert manifest.get('audio_alignment_words') == audio_words, 'Audio alignment word metadata mismatch'
    assert manifest.get('audio_alignment_sha256') == audio_alignment.hexdigest(), 'Audio semantic alignment hash mismatch'

    translation_manifest = json.loads((assets / 'translations-manifest.json').read_text())
    translation_pack = assets / 'translations.sqlite'
    assert hashlib.sha256(translation_pack.read_bytes()).hexdigest() == translation_manifest['sqlite_sha256']
    tdb = sqlite3.connect(f'file:{translation_pack}?mode=ro', uri=True)
    assert tdb.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    coordinates = {row[0] for row in db.execute('SELECT id FROM ayah')}
    edition_ids = [row[0] for row in tdb.execute('SELECT id FROM edition ORDER BY rowid')]
    assert edition_ids == translation_manifest['editions'], 'Translation manifest/database edition drift'
    assert 'urdu_jalandhari' in edition_ids, 'Fateh Muhammad Jalandhry translation must remain in the offline pack'
    assert tdb.execute("SELECT language,title,version,source FROM edition WHERE id='urdu_jalandhari'").fetchone() == ('ur','Urdu Translation - Fateh Muhammad Jalandhry','snapshot-47ca096b','https://tanzil.net/trans/'), 'Jalandhari provenance metadata drift'
    for edition in edition_ids:
        assert {row[0] for row in tdb.execute('SELECT ayah_id FROM translation WHERE edition_id=?', (edition,))} == coordinates
        archived = json.loads((ROOT / 'source-vault/translations' / (edition + '.json')).read_text())
        for chapter in archived.values():
            for row in chapter:
                aid = f"Q:{row['chapter']}:{row['verse']}"
                assert tdb.execute('SELECT text,footnotes FROM translation WHERE edition_id=? AND ayah_id=?',
                                   (edition, aid)).fetchone() == (row['text'], row.get('footnotes', '')), ('Translation drift', edition, aid)
    translations = {}
    for aid, text in tdb.execute('SELECT ayah_id,text FROM translation'):
        translations[aid] = translations.get(aid, '') + ' ' + text
    print(f"Translation source identity: all {6236 * len(edition_ids):,} texts and footnotes match their archived coordinates")
    tdb.close()

    # Quran pronunciation binaries are not build inputs. Only a tiny immutable catalog may ship.
    legacy_audio = ROOT / 'source-vault/quran-audio/active/quran-audio'
    accidental_audio_asset = ROOT / 'app/src/main/assets/quran-audio'
    binary_audio_assets = [
        p for p in assets.rglob('*')
        if p.is_file() and p.suffix.lower() in {'.aqp','.opus','.pb','.pack'}
    ]
    assert not legacy_audio.exists() and not accidental_audio_asset.exists(), 'Legacy bundled Quran audio must not be present'
    assert not binary_audio_assets, 'Quran pronunciation binary leaked into base APK assets'
    audio_catalog_path = assets / 'quran-audio-word-catalog.json'
    assert audio_catalog_path.is_file(), 'Missing isolated-word Quran pronunciation catalog'
    audio_catalog = json.loads(audio_catalog_path.read_text())
    assert audio_catalog['schema'] == 1
    assert audio_catalog['delivery'] == 'ISOLATED_WORD_SURAH_CONTAINER_V1'
    assert audio_catalog['source_revision'] == '9796e08caae700f44266255da320adf6e5ab4114'
    assert audio_catalog['canonical_quran_alignment_sha256'] == audio_alignment.hexdigest()
    assert audio_catalog['canonical_quran_audio_words'] == 77326
    assert audio_catalog['surahs'] == 114
    assert len(audio_catalog['packs']) == 114
    assert sum(int(v['words']) for v in audio_catalog['packs'].values()) == 77326
    assert sum(int(v['bytes']) for v in audio_catalog['packs'].values()) == int(audio_catalog['total_bytes'])
    for surah in range(1,115):
        key=f'{surah:03d}'; meta=audio_catalog['packs'][key]
        assert len(meta['sha256']) == 64 and int(meta['bytes']) > 64 and int(meta['words']) > 0
        assert meta['url'].startswith('https://github.com/warishakhan3548-hash/updating-repository/releases/download/')
        assert meta['url'].endswith('/'+key+'.aqp')

    # Hadith is a separate optional immutable pack. A build must contain both files or neither.
    hadith_manifest_path = assets / 'hadith-manifest.json'
    hadith_pack = assets / 'hadith.sqlite'
    assert hadith_manifest_path.exists() == hadith_pack.exists(), 'Incomplete generated Hadith pack'
    if hadith_pack.exists():
        hmanifest = json.loads(hadith_manifest_path.read_text())
        assert hmanifest['schema_version'] == 2
        assert hashlib.sha256(hadith_pack.read_bytes()).hexdigest() == hmanifest['sqlite_sha256']
        assert hadith_pack.stat().st_size == int(hmanifest['sqlite_bytes']) and int(hmanifest['sqlite_bytes']) > 0
        hdb = sqlite3.connect(f'file:{hadith_pack}?mode=ro', uri=True)
        assert hdb.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert hdb.execute('PRAGMA user_version').fetchone()[0] == 2
        assert hdb.execute('SELECT count(*) FROM collection').fetchone()[0] == hmanifest['collections']
        assert hdb.execute('SELECT count(*) FROM hadith').fetchone()[0] == hmanifest['records']
        assert hdb.execute('SELECT count(*) FROM hadith_fts').fetchone()[0] == hmanifest['records']
        assert hdb.execute('SELECT count(*) FROM search_context').fetchone()[0] == hmanifest.get('search_contexts', 0)
        indexes={row[0] for row in hdb.execute("SELECT name FROM sqlite_master WHERE type='index'")}
        assert 'grade_assertion_lookup' in indexes, 'Hadith grade lookup index missing'
        legacy_shadow_indexes = {row[0] for row in hdb.execute(
            "SELECT name FROM sqlite_master WHERE type='index' AND name IN ('hadith_arabic_shadow','hadith_english_shadow')"
        )}
        assert not legacy_shadow_indexes, f'Unused duplicate Hadith shadow indexes returned: {legacy_shadow_indexes}'
        assert hdb.execute('SELECT count(DISTINCT hadith_rowid) FROM search_token').fetchone()[0] == hmanifest['records']
        assert not hdb.execute('PRAGMA foreign_key_check').fetchall()
        for arabic, expected in hdb.execute('SELECT arabic,source_sha256 FROM hadith'):
            assert hashlib.sha256(arabic.encode()).hexdigest() == expected

        # The translated HadeethEnc lane is source-separated from the core-nine Arabic corpus.
        # Never claim it is installed unless all archived official workbooks and local indexes agree.
        he_source = ROOT / 'source-vault/hadith/hadeethenc/current'
        he_manifest_path = he_source / 'manifest.json'
        if he_manifest_path.exists():
            he_source_manifest = json.loads(he_manifest_path.read_text())
            assert he_source_manifest['provider'] == 'HadeethEnc.com'
            assert he_source_manifest['runtime_network_required'] is False
            he_languages = {item['language']: item for item in he_source_manifest['languages']}
            assert set(he_languages) == {'ar', 'en', 'ur', 'hi'}
            for code, meta in he_languages.items():
                raw = he_source / f'{code}.xlsx'
                assert raw.is_file(), f'Missing archived HadeethEnc {code} workbook'
                assert raw.stat().st_size == int(meta['bytes'])
                assert hashlib.sha256(raw.read_bytes()).hexdigest() == meta['sha256']

            assert hdb.execute("SELECT count(*) FROM collection WHERE id='hadeethenc'").fetchone()[0] == 1
            assert {'ar', 'en', 'ur', 'hi'} <= set(hmanifest.get('language_coverage', []))
            he_records = hdb.execute("SELECT count(*) FROM hadith WHERE collection_id='hadeethenc'").fetchone()[0]
            assert he_records > 0
            for code in ('en', 'ur', 'hi'):
                translated = hdb.execute(
                    "SELECT count(DISTINCT t.hadith_id) FROM editorial_translation t "
                    "JOIN hadith h ON h.id=t.hadith_id "
                    "WHERE h.collection_id='hadeethenc' AND t.language=? "
                    "AND t.status IN ('reviewed','released')", (code,)
                ).fetchone()[0]
                assert translated > 0, f'No installed HadeethEnc {code} translations'
                assert translated == int(hmanifest['imported_translation_record_counts'][code])
                bad_source = hdb.execute(
                    "SELECT count(*) FROM editorial_translation t JOIN hadith h ON h.id=t.hadith_id "
                    "WHERE h.collection_id='hadeethenc' AND t.language=? "
                    "AND t.source_ref NOT LIKE 'HadeethEnc.com%'", (code,)
                ).fetchone()[0]
                assert bad_source == 0, f'HadeethEnc {code} attribution drift'
                if code == 'hi':
                    assert hdb.execute(
                        "SELECT count(*) FROM search_context WHERE language='hi' AND trim(roman)<>''"
                    ).fetchone()[0] > 0, 'Hindi HadeethEnc context has no Hinglish search shadow'

                # Prove a real translated token participates in the local inverted index.
                sample = hdb.execute(
                    "SELECT h.rowid,t.text FROM editorial_translation t JOIN hadith h ON h.id=t.hadith_id "
                    "WHERE h.collection_id='hadeethenc' AND t.language=? "
                    "AND t.status IN ('reviewed','released') ORDER BY h.rowid LIMIT 1", (code,)
                ).fetchone()
                assert sample is not None
                tokens = [token for token in hadith_search_text(sample[1]).split() if len(token) >= 3]
                assert tokens, f'No searchable HadeethEnc {code} token'
                assert any(hdb.execute(
                    "SELECT 1 FROM search_token WHERE hadith_rowid=? AND token=? LIMIT 1",
                    (sample[0], token)
                ).fetchone() for token in tokens[:12]), f'HadeethEnc {code} translation missing from search index'

            # No guessed cross-edition attachment: core-nine records keep their own source identity.
            assert hdb.execute(
                "SELECT count(*) FROM hadith WHERE collection_id<>'hadeethenc' "
                "AND source_ref LIKE 'HadeethEnc.com%'"
            ).fetchone()[0] == 0
        hdb.close()
    android = '{http://schemas.android.com/apk/res/android}'
    android_manifest = ET.parse(ROOT / 'app/src/main/AndroidManifest.xml').getroot()
    application = android_manifest.find('application')
    assert application.get(android + 'name') == '.QuranApp', 'Missing startup wiring'
    main_activity = next(a for a in application.findall('activity') if a.get(android + 'name') == '.MainActivity')
    assert main_activity.get(android + 'theme') == '@style/AppLaunchTheme', 'Main activity must use the launch theme'
    styles_text = (ROOT / 'app/src/main/res/values/styles.xml').read_text(encoding='utf-8')
    api27_styles = (ROOT / 'app/src/main/res/values-v27/styles.xml').read_text(encoding='utf-8')
    splash_styles = (ROOT / 'app/src/main/res/values-v31/styles.xml').read_text(encoding='utf-8')
    splash_icon = (ROOT / 'app/src/main/res/drawable/ic_quran_splash.xml').read_text(encoding='utf-8')
    assert 'name="AppLaunchTheme"' in styles_text
    assert 'android:windowLightNavigationBar' not in styles_text and 'android:windowLayoutInDisplayCutoutMode' not in styles_text, 'API 26 base theme must not reference API 27-only window attributes'
    assert 'android:windowLightNavigationBar' in api27_styles and 'android:windowLayoutInDisplayCutoutMode' in api27_styles, 'API 27 theme must restore navigation-bar and display-cutout behavior'
    assert 'android:windowSplashScreenAnimatedIcon' in splash_styles
    assert '@drawable/ic_quran_splash' in splash_styles
    assert '<vector' in splash_icon and '#D8C28A' in splash_icon
    permissions = {p.get(android + 'name') for p in android_manifest.findall('uses-permission')}
    java_sources = '\n'.join(p.read_text(encoding='utf-8') for p in (ROOT / 'app/src/main/java').rglob('*.java'))
    assert 'https://sunnah.com/' not in java_sources, 'Runtime Hadith website dependency returned'

    # Translation speech must recover automatically when Android removes or renames a saved offline voice.
    translation_speech_text = (ROOT / 'app/src/main/java/com/aaris/quran/TranslationSpeech.java').read_text(encoding='utf-8')
    assert 'TranslationSpeech(Context context){this.context=context.getApplicationContext();}' in translation_speech_text, 'Translation speech must not retain an Activity context across slow TTS initialization'
    assert 'private Voice preferredVoice(String language,List<Voice> available)' in translation_speech_text, 'Translation speech must resolve a usable offline voice centrally'
    assert 'preferences.edit().putString(language,voiceKey(fallback)).apply();' in translation_speech_text, 'A stale or missing voice preference must be repaired to the best installed offline voice'
    assert 'Voice selected=preferredVoice(entry.edition.language,available);' in translation_speech_text, 'Translation playback must use the resilient voice resolver'
    assert 'Voice current=preferredVoice(sample.edition.language,available);' in translation_speech_text, 'Voice chooser must display the same effective voice used for playback'
    assert 'Your saved device voice is unavailable' not in translation_speech_text, 'A stale saved voice must not block another installed offline voice'

    # Appearance Studio must preserve Arabic shaping while keeping transparent surfaces readable.
    appearance_text = (ROOT / 'app/src/main/java/com/aaris/quran/Appearance.java').read_text(encoding='utf-8')
    appearance_studio_text = (ROOT / 'app/src/main/java/com/aaris/quran/AppearanceStudio.java').read_text(encoding='utf-8')
    arabic_text = (ROOT / 'app/src/main/java/com/aaris/quran/ArabicText.java').read_text(encoding='utf-8')
    glass_text = (ROOT / 'app/src/main/java/com/aaris/quran/Glass.java').read_text(encoding='utf-8')
    quran_text = (ROOT / 'app/src/main/java/com/aaris/quran/QuranText.java').read_text(encoding='utf-8')
    assert '.put("version",9)' in appearance_text, 'Appearance persistence schema was not upgraded safely'
    assert 'effectiveCardOpacity()' in appearance_text and 'effectiveSurfaceAtGradientEnd()' in appearance_text and 'surfaceHighlightAtGradientEnd()' in appearance_text
    assert 'boolean rendersGradient(){return gradient&&!reducedEffects;}' in appearance_text, 'Reduced-effects mode must remove hidden gradient endpoints from contrast calculations'
    assert 'if(style.rendersGradient())' in appearance_studio_text, 'Appearance preview must use the same gradient visibility rule as runtime'
    assert 'style.font=index;style.name="My style";commit();renderControls();' in appearance_studio_text, 'Changing the Quran writing style must clear a stale preset identity'
    for mutation in ('style.textFinish=finishIndex;style.textGlass=finishIndex==Appearance.TEXT_GLASS;style.name="My style"', 'style.glass=true;style.name="My style"', 'style.glass=false;style.name="My style"', 'style.autoBalance=!style.autoBalance;style.name="My style"', 'style.reducedEffects=!style.reducedEffects;style.name="My style"', 'style.gradient=true;style.name="My style"', 'style.autoShadowColor=!style.autoShadowColor;style.name="My style"', 'style.autoBalance=true;style.autoBalanceEffects();style.name="My style"', 'style.gradient=false;style.name="My style"'):
        assert mutation in appearance_studio_text, 'Appearance mutations must not leave a preset falsely selected'
    assert 'private void normalizeEditingLayer()' in appearance_studio_text and 'if(layer==5&&!style.gradient){layer=0;invalidateEditorColor();}' in appearance_studio_text, 'Appearance undo/redo must not leave a hidden gradient layer selected'
    assert 'b.setMinHeight(dp(activity,48))' in appearance_studio_text, 'Appearance compact choices must keep the Android 48dp minimum touch target'
    assert 'line.addView(seek,new LinearLayout.LayoutParams(0,dp(activity,48),1));' in appearance_studio_text, 'Appearance sliders must keep a 48dp touch target'
    assert appearance_studio_text.count('new LinearLayout.LayoutParams(dp(activity,48),dp(activity,48))') >= 2, 'Appearance palette swatches must use 48dp tappable containers'
    assert 'outer.addView(visual,new FrameLayout.LayoutParams(dp(activity,27),dp(activity,27),Gravity.CENTER));' in appearance_studio_text, 'Palette visual dots must stay compact inside the larger touch target'
    assert 'visual.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);' in appearance_studio_text, 'Palette swatches must expose one semantic accessibility node instead of duplicate inner-dot nodes'
    assert 'HorizontalScrollView palette=new HorizontalScrollView(activity)' in appearance_studio_text and 'palette.addView(dots,new HorizontalScrollView.LayoutParams(-2,-2));controls.addView(palette);' in appearance_studio_text, 'Expanded palette touch targets must remain usable on narrow screens'
    assert 'new LinearLayout.LayoutParams(dp(activity,118),dp(activity,48))' in appearance_studio_text, 'Saved appearance chips must keep a 48dp touch target'
    assert 'boolean canUndo=historyIndex>0,canRedo=historyIndex+1<history.size();' in appearance_studio_text, 'Appearance history controls must derive enabled state from the real history cursor'
    assert 'undo.setEnabled(canUndo);undo.setFocusable(canUndo);undo.setAlpha(canUndo?1f:.45f);' in appearance_studio_text and 'redo.setEnabled(canRedo);redo.setFocusable(canRedo);redo.setAlpha(canRedo?1f:.45f);' in appearance_studio_text, 'Unavailable Undo/Redo controls must be visibly and semantically disabled instead of silently no-oping'
    assert 'private void renderControls(){\n        normalizeEditingLayer();' in appearance_studio_text, 'Appearance editor must normalize its editing target before rebuilding controls'
    assert '!highContrast&&appearance.rendersGradient()&&backgroundGradient!=null' in glass_text, 'Runtime backdrop must share the appearance gradient visibility rule'
    assert 'TEXT_PLAIN=0,TEXT_SOFT=1,TEXT_GLASS=2,TEXT_FOIL=3' in appearance_text
    assert 'shadowAngle' in appearance_text and 'shadowDistance' in appearance_text and 'gradientAngle' in appearance_text
    assert 'style.readabilitySummary()' in appearance_studio_text and 'Smart balance' in appearance_studio_text
    assert 'Shadow angle' in appearance_studio_text and 'Gradient angle' in appearance_studio_text
    assert 'style.textFinish!=Appearance.TEXT_PLAIN' in arabic_text and 'Appearance.TEXT_FOIL' in arabic_text
    assert 'cachedGradientSurface!=style.effectiveSurfaceAtGradientEnd()' in arabic_text
    assert 'shadowDistance=0' in appearance_text, 'Legacy saved themes must keep the previous zero-distance shadow default'
    assert 'wordHighlighted||getSelectionStart()!=getSelectionEnd()' in arabic_text, 'Selected Quran text must bypass decorative shaders'
    assert 'android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE' in quran_text, 'Quran TextView must use the SDK-declared break-strategy constant so Android lint can validate it'
    assert 'appearance.effectiveCardOpacity()' in glass_text and 'appearance.effectiveBorderStrength()' in glass_text
    assert 'cachedGradientAngle!=appearance.gradientAngle' in glass_text
    assert 'setLetterSpacing(' not in quran_text and 'setLetterSpacing(' not in arabic_text, 'Do not alter Quran Arabic tracking/shaping'

    # Large Hadith-pack browsing must never regress to synchronous SQLite reads on the Android UI thread.
    main_activity_text = (ROOT / 'app/src/main/java/com/aaris/quran/MainActivity.java').read_text(encoding='utf-8')
    quran_app_text = (ROOT / 'app/src/main/java/com/aaris/quran/QuranApp.java').read_text(encoding='utf-8')
    learning_store_text = (ROOT / 'app/src/main/java/com/aaris/quran/LearningStore.java').read_text(encoding='utf-8')
    backup_validator_text = (ROOT / 'app/src/main/java/com/aaris/quran/BackupValidator.java').read_text(encoding='utf-8')
    content_store_text = (ROOT / 'app/src/main/java/com/aaris/quran/ContentStore.java').read_text(encoding='utf-8')
    translation_store_text = (ROOT / 'app/src/main/java/com/aaris/quran/TranslationStore.java').read_text(encoding='utf-8')
    hadith_store_text = (ROOT / 'app/src/main/java/com/aaris/quran/HadithStore.java').read_text(encoding='utf-8')
    quran_audio_store_text = (ROOT / 'app/src/main/java/com/aaris/quran/QuranAudioStore.java').read_text(encoding='utf-8')
    quran_audio_downloads_text = (ROOT / 'app/src/main/java/com/aaris/quran/QuranAudioDownloadManager.java').read_text(encoding='utf-8')
    word_audio_player_text = (ROOT / 'app/src/main/java/com/aaris/quran/WordAudioPlayer.java').read_text(encoding='utf-8')
    recitation_downloads_text = (ROOT / 'app/src/main/java/com/aaris/quran/RecitationDownloads.java').read_text(encoding='utf-8')
    recitation_service_text = (ROOT / 'app/src/main/java/com/aaris/quran/RecitationService.java').read_text(encoding='utf-8')
    ambient_service_text = (ROOT / 'app/src/main/java/com/aaris/quran/AmbientRecallService.java').read_text(encoding='utf-8')
    assert 'cleanupOldPacks(folder,target);' in content_store_text and '"install.tmp".equals(name)' in content_store_text, 'Verified Quran pack updates must reclaim obsolete database/staging files'
    assert '"translations.installing".equals(file.getName())' in translation_store_text, 'Verified translation pack updates must reclaim an abandoned install staging file'
    assert 'try{writeVerificationMarker(marker,target,packHash,packBytes);}' in hadith_store_text and 'catch(IOException ignored){}' in hadith_store_text, 'A failed Hadith verification-marker optimization must not hide a cryptographically verified evidence pack'
    assert 'recoverInterruptedInstalls();' in quran_audio_store_text and 'validateContainer(target,meta,true);' in quran_audio_store_text and 'if(!target.exists()&&old.renameTo(target))delete(markerFile(surah));' in quran_audio_store_text, 'Interrupted Quran audio replacement must verify a new target before discarding the rollback pack and restore the rollback when needed'
    assert 'cleanupObsoletePartials();' in quran_audio_store_text and 'name.startsWith(".partial-")' in quran_audio_store_text, 'Quran audio must discard resumable partials from obsolete immutable source revisions'
    assert 'try{writeMarker(marker,markerValue(file,meta));}catch(IOException ignored){}' in quran_audio_store_text, 'A failed optimization marker write must not invalidate a fully verified Quran audio pack'
    assert 'int completed=0,current=0;String failure=null;' in quran_audio_downloads_text and 'completed=store.installedCount();' in quran_audio_downloads_text, 'Word-audio Download All must enter its recovery/finally path before installed-pack inspection can fail'
    assert 'AudioManager.ACTION_AUDIO_BECOMING_NOISY' in word_audio_player_text and 'registerNoisyReceiverLocked();' in word_audio_player_text, 'Word pronunciation playback must stop if a private audio route disconnects'
    assert 'Context.RECEIVER_NOT_EXPORTED' in word_audio_player_text and 'unregisterNoisyReceiverLocked();abandonFocus();' in word_audio_player_text, 'Word-audio noisy-route receiver must stay private and be released with playback state'
    audio_install_start = quran_audio_store_text.index('    synchronized void installDownloaded(')
    audio_install_end = quran_audio_store_text.index('\n    private static SurahIndex parseIndex', audio_install_start)
    audio_install = quran_audio_store_text[audio_install_start:audio_install_end]
    assert 'SurahIndex index=parseIndex(target,meta,false);' in audio_install and 'try{writeMarker(marker,markerValue(target,meta));}catch(IOException ignored){}' in audio_install, 'Installing a verified word-audio pack must not roll back solely because its optimization marker cannot be written'
    assert 'legacyRoot=new File(c.getFilesDir(),"recitations-v1")' in recitation_downloads_text and 'void cleanupLegacyCache()' in recitation_downloads_text, 'Wrong-coordinate legacy recitation bytes must have an explicit cleanup path'
    assert 'connection.setInstanceFollowRedirects(true)' in recitation_downloads_text and 'connection.setInstanceFollowRedirects(false)' not in recitation_downloads_text, 'Whole-ayah recitation downloads must tolerate normal HTTPS CDN redirects'
    assert 'connection.getURL().getProtocol()' in recitation_downloads_text and 'redirected away from HTTPS' in recitation_downloads_text, 'Recitation redirect handling must reject transport downgrade'
    assert 'connection.setRequestProperty("Range","bytes="+existing+"-")' in recitation_downloads_text and 'connection.setRequestProperty("If-Range",state.validator)' in recitation_downloads_text, 'Interrupted whole-ayah downloads must resume only against the validator-bound remote representation'
    assert 'connection.getHeaderField("Content-Range")' in recitation_downloads_text and 'contentRangeTotal(' in recitation_downloads_text, 'Resumed whole-ayah bytes must validate the returned byte range before appending'
    assert 'ResumeState readResumeState' in recitation_downloads_text and 'writeResumeState(resume,stableValidator,total)' in recitation_downloads_text, 'Whole-ayah resume metadata must survive cancellation so the current ayah can continue instead of restarting'
    assert 'Incomplete audio; retry will resume' in recitation_downloads_text and 'finally{' in recitation_downloads_text, 'Interrupted whole-ayah transfers must preserve valid partial bytes for retry'
    assert 'clearPartial(temporary,resume)' in recitation_downloads_text, 'Invalid or unbound whole-ayah partials must be discarded before reuse'
    assert 'directory.getUsableSpace()' in recitation_downloads_text and 'STORAGE_HEADROOM_BYTES' in recitation_downloads_text, 'Whole-ayah downloads must fail cleanly before exhausting known available storage'
    assert 'recitationDownloadWorker.execute(recitationDownloads::cleanupLegacyCache);' in quran_app_text, 'Legacy recitation cleanup must run away from the Android UI thread'
    assert 'private boolean ensureWindowEnvironment()' in ambient_service_text and 'if(display==null)return false;' in ambient_service_text and 'createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,null)' in ambient_service_text, 'Ambient recall must wait for a display-associated window context instead of using a non-visual Service context on API 30+'
    assert 'if(!ensureWindowEnvironment()){handler.removeCallbacks(tick);handler.postDelayed(this::prepareCard,1000L);return;}' in ambient_service_text, 'A transiently unavailable display must retry the pending recall card without crashing or consuming the recall interval'
    assert 'layout.setPadding(left,top,right,bottom);overlay.setPadding(left,top,right,bottom);' in main_activity_text, 'Interactive UI must consume system/IME insets without insetting the full-screen themed backdrop'
    assert 'view.setPadding(edges.left,edges.top,edges.right,edges.bottom)' not in main_activity_text, 'Do not regress Android 15 edge-to-edge by padding the root/backdrop away from system bars'
    activity_result_start = main_activity_text.index('    @Override protected void onActivityResult')
    activity_result_end = main_activity_text.index('\n    @Override public void onBackPressed', activity_result_start)
    activity_result = main_activity_text[activity_result_start:activity_result_end]
    assert 'final AtomicBoolean exportPrepareBusy=new AtomicBoolean(false);' in quran_app_text, 'Export preparation must remain globally reserved across Activity recreation'
    assert 'final AtomicBoolean exportWriteBusy=new AtomicBoolean(false);' in quran_app_text, 'Destination writes need application-scoped busy state so Activity recreation cannot unlock a concurrent export'
    assert 'static final class PreparedExportResult' in quran_app_text and 'PreparedExportResult takePreparedExportResult()' in quran_app_text, 'Prepared export handoff must live in application-scoped state'
    assert 'preparedExportListener=this::deliverPreparedExportResult;app.preparedExportChanged=preparedExportListener' in main_activity_text, 'The current Activity must attach to prepared export results'
    assert 'resumed=true;deliverResearchPdfResult();deliverPreparedExportResult();' in main_activity_text, 'Prepared exports must be claimed only after the recreated Activity resumes'
    assert 'app.preparedExportChanged==preparedExportListener' in main_activity_text, 'Destroyed Activities must detach from prepared export delivery without discarding the pending result'
    assert 'QuranApp.PreparedExportResult result=app.takePreparedExportResult();' in main_activity_text, 'The resumed Activity must atomically claim one prepared export'
    assert 'app.publishPreparedExport(token,name,type)' in main_activity_text and 'app.publishPreparedExportFailure(' in main_activity_text, 'Export preparation must publish success and failure through lifecycle-safe application state'
    assert 'static final class RestoreImportResult' in quran_app_text and 'synchronized RestoreImportResult peekRestoreImportResult()' in quran_app_text, 'Validated backup imports must remain application-scoped until the user decides'
    assert 'clearRestoreImportResult(RestoreImportResult expected)' in quran_app_text, 'Restore confirmation must clear only the exact pending import it displayed'
    assert 'restoreImportListener=this::deliverRestoreImportResult;app.restoreImportChanged=restoreImportListener' in main_activity_text, 'The current Activity must attach to pending restore-import results'
    assert 'deliverPreparedExportResult();deliverRestoreImportResult();' in main_activity_text, 'Pending restore confirmation must be re-delivered after Activity recreation'
    assert 'app.restoreImportChanged==restoreImportListener' in main_activity_text, 'Destroyed Activities must detach restore-import delivery without clearing the pending backup'
    assert 'preparingExport' not in main_activity_text, 'Do not regress export preparation to Activity-local busy state'
    assert 'ui.post(()->{if(!isDestroyed())saveFile(' not in main_activity_text, 'Prepared export completion must not depend on the old Activity handler'
    assert 'EvidenceExporter.build(appContext,content,selection,query,traces)' in main_activity_text, 'Evidence export preparation must not retain the old Activity as its Context'
    assert 'app.exportWriteBusy.set(true);app.notifyOperationChanged();app.io.execute' in activity_result, 'Export must stay visibly busy while the staged file is copied to the chosen destination'
    assert 'finally{discardExport(token);app.exportWriteBusy.set(false);app.notifyOperationChanged();}' in activity_result, 'Destination-write busy state must clear only after the staged token has been consumed or discarded'
    assert 'ui.post(()->toast("File saved"))' not in activity_result, 'Do not report export completion from the old pre-lifecycle completion path'
    assert 'app.publishRestoreImport(backup,count)' in activity_result and 'app.publishRestoreImportFailure(' in activity_result, 'Backup validation success and failure must publish through lifecycle-safe application state'
    assert 'app.getContentResolver().openInputStream(uri)' in activity_result and 'app.learning.validateBackup(backup,app.content)' in activity_result, 'Backup parsing must not retain the Activity while validation runs'
    assert 'MAX_FUTURE_EVENT_SKEW=5*Recall.MINUTE' in learning_store_text and 'if(lastEventTime>now+MAX_FUTURE_EVENT_SKEW)lastEventTime=now;' in learning_store_text, 'Learning event creation must recover from an imported or legacy clock that is implausibly far in the future'
    assert 'String order="event".equals(table)?" ORDER BY seq":"";' in learning_store_text and '"SELECT * FROM "+table+order' in learning_store_text, 'Learning backups must serialize event rows in stable ledger sequence order'
    assert 'MAX_FUTURE_EVENT_SKEW=5*Recall.MINUTE' in backup_validator_text and 'timestamp(row,"at")>now+MAX_FUTURE_EVENT_SKEW' in backup_validator_text, 'Backup validation must reject learning events that would poison the local scheduler clock'
    assert 'pendingRestore' not in main_activity_text, 'Do not keep validated backup payloads in Activity-local state where rotation can discard them'
    assert 'ui.post(()->{if(isDestroyed())return;pendingRestore=backup' not in activity_result, 'Restore preparation must not depend on the Activity that launched validation'
    assert 'pendingExport!=null||app.exportWriteBusy.get()||!app.exportPrepareBusy.compareAndSet(false,true)' in main_activity_text, 'A new export must be blocked by local picker state, destination writes, or an in-flight prepared handoff'
    assert 'exportBusy=app.exportPrepareBusy.get()||app.exportWriteBusy.get()' in main_activity_text, 'Existing operation UI must reflect both export preparation and destination writing'
    assert main_activity_text.count('Preparing or saving export on your phone…') >= 2, 'Operation status must describe both export preparation and destination writes'
    assert 'WindowInsetsController controller=getWindow().getInsetsController();' in main_activity_text and 'controller.setSystemBarsAppearance(lightBars?light:0,light);' in main_activity_text, 'API 30+ system-bar icon contrast must use WindowInsetsController instead of deprecated visibility flags'
    assert 'if(Build.VERSION.SDK_INT<35){getWindow().setStatusBarColor(appearance.background);getWindow().setNavigationBarColor(appearance.background);}' in main_activity_text, 'Android 15 edge-to-edge must not depend on disabled system-bar color setters'
    assert 'row.setContentDescription(bookLabel+". "+book.count+" records")' in main_activity_text, 'Focusable Hadith book rows must expose a TalkBack label'
    assert 'row.setContentDescription(word.arabic+". "+gloss+(remembered?". Remembered":". Add to memory"))' in main_activity_text and 'row.setContentDescription(word.arabic+". "+gloss+". Remembered")' in main_activity_text, 'Ambient memory rows must expose and refresh their semantic action state'
    assert 'row.setContentDescription(word.arabic+". "+meaning+". Open word details")' in main_activity_text, 'Word-by-word detail rows must expose a TalkBack action label'
    assert 'private void updateHighContrast(boolean enabled)' in main_activity_text and 'contrast.setOnCheckedChangeListener((b,v)->updateHighContrast(v));' in main_activity_text, 'High-contrast setting must use the live surface refresh path'
    assert 'highContrast=enabled;learning.set("contrast",""+enabled);\n        show();settings();' in main_activity_text, 'High-contrast changes must rebuild both the underlying screen and the open settings sheet immediately'
    assert 'state.putStringArrayList("hadith_evidence",new ArrayList<>(selectedHadith))' in main_activity_text, 'Selected Hadith evidence must survive Activity recreation'
    assert 'ArrayList<String> hadithIds=state.getStringArrayList("hadith_evidence")' in main_activity_text, 'Recreated search must restore selected Hadith evidence before results render'
    assert 'boolean sameHadithQuery=nextQuery.equals(hadithQuery);' in main_activity_text and 'if(!sameHadithQuery)selectedHadith.clear();' in main_activity_text, 'Same-query Hadith refreshes must preserve user selection while genuinely new queries clear stale IDs'
    assert 'selectedHadith.size()>=ResearchExport.MAX_RECORDS' in main_activity_text and 'Select up to "+ResearchExport.MAX_RECORDS+" Hadith records per PDF' in main_activity_text, 'Hadith selection UI must enforce the same export cap before the user reaches PDF generation'
    assert 'hadithBrowseWorker=worker("hadith-browse")' in quran_app_text, 'Missing dedicated Hadith browse worker'
    assert 'recitationStatusWorker=worker("recitation-status")' in quran_app_text, 'Recitation download status scans need a dedicated background worker'
    def java_method(name, return_type='void', marker=None):
        marker = marker or f'    private {return_type} {name}('
        start = main_activity_text.index(marker)
        end = main_activity_text.find('\n    private ', start + len(marker))
        return main_activity_text[start:] if end < 0 else main_activity_text[start:end]
    restore_import_delivery = java_method('deliverRestoreImportResult')
    assert 'QuranApp.RestoreImportResult result=app.peekRestoreImportResult();' in restore_import_delivery, 'Restore confirmation must read the retained validated backup instead of Activity-local state'
    assert 'restorePrompt=prompt' in restore_import_delivery and 'app.clearRestoreImportResult(result)' in restore_import_delivery, 'Restore confirmation must survive recreation and clear only on a real user decision'
    research_pdf_delivery = java_method('deliverResearchPdfResult')
    research_pdf_share = java_method('shareResearch', marker='    private void shareResearch(boolean hadith,List<HadithStore.Hit> resolvedHadithHits){')
    assert 'static final class ResearchPdfResult' in quran_app_text and 'synchronized ResearchPdfResult takeResearchPdfResult()' in quran_app_text, 'Research PDF completion must survive Activity recreation in application-scoped state'
    assert 'researchPdfListener=this::deliverResearchPdfResult;app.researchPdfChanged=researchPdfListener' in main_activity_text, 'The current Activity must attach to pending research PDF results'
    assert 'resumed=true;deliverResearchPdfResult();' in main_activity_text, 'Pending research PDFs must be delivered after recreation when the Activity is resumed'
    assert 'app.researchPdfChanged==researchPdfListener' in main_activity_text, 'Destroyed Activities must detach the research PDF listener without clearing pending results'
    assert 'application.publishResearchPdf(uri,researchPrompt);' in research_pdf_share and 'application.publishResearchPdfFailure(' in research_pdf_share, 'Research PDF success and failure must publish through lifecycle-safe application state'
    assert 'ResearchPdfUi' not in main_activity_text, 'Do not regress to an Activity-bound research PDF callback that drops results on recreation'
    assert 'QuranApp.ResearchPdfResult result=app.takeResearchPdfResult();' in research_pdf_delivery and 'Intent.ACTION_SEND' in research_pdf_delivery, 'The resumed Activity must atomically claim and share one pending PDF result'
    assert 'ResearchFiles.discard(getApplicationContext(),result.uri)' in research_pdf_delivery, 'If no receiving app exists, the claimed PDF cache file must be discarded'
    today_method = java_method('today')
    assert 'final Ayah resumeTarget=resume;' in today_method and 'audioControls(resumeTarget)' in today_method, 'Today recitation controls must target the exact ayah shown in Where You Left Off'
    assert 'audioControls(content.ayah("Q:"+readerSurah+":"+readerStart))' not in today_method, 'Today recitation controls must not regress to the canonical 8-ayah page start'
    for method in ('hadithCollection', 'hadithBook', 'hadithRecordsPage', 'hadithRecord'):
        assert 'hadithBrowseWorker.submit' in java_method(method), f'{method} must load Hadith data off the UI thread'
    hadith_collection = java_method('hadithCollection')
    hadith_book = java_method('hadithBook')
    hadith_records_page = java_method('hadithRecordsPage')
    hadith_records_render = java_method('renderHadithRecordsPage')
    assert 'store.records(collectionId,null,null,51,0)' in hadith_collection, 'Collection fallback must fetch one lookahead Hadith record'
    assert 'store.records(collectionId,book.id,null,51,0)' in hadith_book, 'Book fallback must fetch one lookahead Hadith record'
    assert 'store.records(collectionId,bookId,chapterId,51,offset)' in hadith_records_page, 'Hadith record pages must fetch one lookahead row'
    assert 'boolean hasNext=records.size()>size;' in hadith_records_render, 'Hadith pager must derive Next from a real lookahead row'
    assert 'records.subList(0,visibleCount)' in hadith_records_render, 'Hadith pager must not render the lookahead row'
    assert 'records.size()==size' not in hadith_records_render, 'A full final Hadith page must not expose a false Next action'
    hadith_search_page = java_method('loadHadithSearch')
    hadith_search_batch = java_method('appendHadithBatch')
    assert 'setSearchBusy(true);status.setText("Loading next Hadith matches…");' in hadith_search_page, 'Hadith search pagination must show immediate progress instead of silently removing the load-more control'
    assert 'pendingSearchJobs++;' in hadith_search_page and 'finishSearch(signal)' in hadith_search_page, 'Hadith search pagination progress must remain tied to the real background search lifecycle'
    assert 'more.setEnabled(false);more.setText("Loading next 50 Hadith matches…");' in hadith_search_page, 'Hadith pagination must keep the existing load-more control visible while loading'
    assert 'more.getParent() instanceof ViewGroup' in hadith_search_page and 'removeView(more)' in hadith_search_page, 'Hadith pagination should remove the old load-more control only after the next page succeeds'
    assert 'more.setEnabled(true);more.setText("Load next 50 Hadith matches");' in hadith_search_page and 'Retry below.' in hadith_search_page, 'Hadith pagination failures must restore the same retry control'
    assert 'catch(CancellationException|OperationCanceledException ignored){ui.post' in hadith_search_page and 'searchGeneration.get()==generation&&more!=null&&more.isAttachedToWindow()' in hadith_search_page, 'Timed-out Hadith pagination must restore retry unless the search generation has actually changed'
    assert 'list.removeView(more)' not in hadith_search_batch and 'loadHadithSearch(q,response.nextOffset,generation,list,status,more)' in hadith_search_batch, 'Hadith load-more taps must not destroy their only retry affordance before success'
    quran_search_page = java_method('loadQuranResults')
    quran_search_batch = java_method('appendQuranBatch')
    assert 'more.setEnabled(false);more.setText("Loading next 50 Quran matches…");' in quran_search_page, 'Quran pagination must keep the existing load-more control visible while loading'
    assert 'more.getParent() instanceof ViewGroup' in quran_search_page and 'removeView(more)' in quran_search_page, 'Quran pagination should remove the old load-more control only after the next page succeeds'
    assert 'more.setEnabled(true);more.setText("Load next 50 matches");' in quran_search_page and 'Retry below.' in quran_search_page, 'Quran pagination failures must restore the same retry control'
    assert 'catch(CancellationException ignored){ui.post' in quran_search_page and 'searchGeneration.get()==generation&&more!=null&&more.isAttachedToWindow()' in quran_search_page, 'Cancelled Quran pagination must restore retry only while the same search is still active'
    assert 'list.removeView(more)' not in quran_search_batch and 'loadQuranResults(list,response,end,status,generation,more)' in quran_search_batch, 'Quran load-more taps must not destroy their only retry affordance before success'
    recitation_status = java_method('fillRecitationSurahDownloads')
    recitation_rows = java_method('appendRecitationSurahDownloads')
    recitation_controls = java_method('audioControls')
    reader_recitation_verify = java_method('verifyReaderRecitationState')
    current_recitation_verify = java_method('verifyCurrentRecitationState')
    reader_method = java_method('reader')
    assert 'int markedCompleteState(String reciter,int surah,int ayahs)' in recitation_downloads_text, 'Render hot paths need a non-blocking recitation completion tri-state'
    assert 'completionCache.get(key)' in recitation_downloads_text and 'missingCompletions.contains(key)?0:-1' in recitation_downloads_text, 'Recitation tri-state must consult memory only and expose unknown without filesystem I/O'
    assert 'markedComplete(' not in reader_method, 'Quran reader rendering must not parse recitation completion markers on the Android UI thread'
    assert 'markedCompleteState(' in reader_method and 'verifyReaderRecitationState(' in reader_method, 'Quran reader must render from cached recitation state and verify unknown state asynchronously'
    assert 'recitationStatusWorker.execute' in reader_recitation_verify and 'downloads.markedComplete(' in reader_recitation_verify, 'Reader recitation verification must use the dedicated background status worker'
    assert 'pageId.equals(renderedPage)' in reader_recitation_verify and 'play.isAttachedToWindow()' in reader_recitation_verify, 'Async reader recitation status must reject stale or detached UI'
    assert 'markedComplete(' not in recitation_controls, 'Opening or tapping recitation controls must not parse completion markers on the Android UI thread'
    assert 'markedCompleteState(' in recitation_controls and 'verifyCurrentRecitationState(' in recitation_controls, 'Recitation controls must use cached state with asynchronous verification for unknown status'
    assert 'String savedReciter=preferences.getString("reciter",RecitationDownloads.IDS[0]);' in recitation_controls and 'String selected=RecitationDownloads.valid(savedReciter);' in recitation_controls, 'Recitation controls must normalize stale saved reciter ids before rendering or verification'
    assert 'if(!selected.equals(savedReciter))preferences.edit().putString("reciter",selected).apply();' in recitation_controls, 'Recovered reciter selection must be persisted so async status checks use the same canonical id'
    assert 'recitationStatusWorker.execute' in current_recitation_verify and 'downloads.markedComplete(' in current_recitation_verify, 'Current-Surah recitation status verification must run off the Android UI thread'
    assert 'dialog.isShowing()' in current_recitation_verify and 'status.isAttachedToWindow()' in current_recitation_verify, 'Recitation sheet status results must be lifecycle-safe'
    assert 'private volatile int recitationListGeneration;' in main_activity_text, 'Recitation status generation must be visible across UI and background threads'
    assert 'recitationListGeneration++' in recitation_controls and 'setOnDismissListener' in recitation_controls, 'Closing recitation controls must invalidate any stale background status scan'
    assert 'recitationStatusWorker.execute' in recitation_status, 'Recitation Surah status discovery must run off the Android UI thread'
    assert 'markedComplete(' in recitation_status, 'Background recitation status discovery must use the existing verified completion marker'
    assert 'markedComplete(' not in recitation_rows, 'Rendering the 114-Surah download list must not perform filesystem status reads on the UI thread'
    assert '!list.isAttachedToWindow()' in recitation_rows, 'Detached recitation sheets must stop incremental row rendering'
    play_start = main_activity_text.index('    private void playAyah(Ayah a){')
    play_end = main_activity_text.index('\n    private void audioControls', play_start)
    play_flow = main_activity_text[play_start:play_end]
    assert 'recitationStatusWorker.execute' in play_flow, 'Paused reciter verification must run off the Android UI thread'
    assert 'downloads.ayahReady(reciter,a,ayahCount)' in play_flow, 'Background playback selection must keep strong saved-reciter verification'
    assert 'app.recitationDownloads.ayahReady(' not in play_flow, 'Play-button flow must not hash paused reciter audio synchronously'
    assert 'private static boolean verifiedAudioFile(File audio,File digest,long expectedLength)' in recitation_downloads_text, 'Whole-ayah cache reuse needs one strong digest verifier for completed and paused recitations'
    assert 'expected.matches("[a-f0-9]{64}")&&expected.equals(ContentStore.hash(audio))' in recitation_downloads_text, 'Saved recitation reuse must verify the actual MP3 bytes, not only file length'
    ayah_ready_start = recitation_downloads_text.index('    boolean ayahReady(')
    ayah_ready_end = recitation_downloads_text.index('\n    /** Strong whole-Surah verification.', ayah_ready_start)
    ayah_ready = recitation_downloads_text[ayah_ready_start:ayah_ready_end]
    assert 'verifiedAudioFile(audio,digest,expectedLength)' in ayah_ready, 'Completed Surah playback selection must reject same-length corrupted ayah audio'
    strong_ready_start = recitation_downloads_text.index('    boolean ready(')
    strong_ready_end = recitation_downloads_text.index('\n    private static final class ResumeState', strong_ready_start)
    strong_ready = recitation_downloads_text[strong_ready_start:strong_ready_end]
    assert 'verifiedAudioFile(audio,digest,lengths[i])' in strong_ready, 'Whole-Surah completion verification must bind every cached MP3 to its SHA-256 sidecar'
    assert 'generation==wordAudioPlayGeneration' in play_flow and 'app.recitationDownloads==downloads' in play_flow, 'Async reciter verification must reject stale playback results'
    assert 'reciter.equals(verifiedReciter)' in play_flow, 'Changing reciter while verification is running must invalidate the old result'
    assert 'wordFallbackReady&&(verifiedReciter==null||!reciter.equals(verifiedReciter))' in play_flow, 'Reciter verification should run only when it can affect word-audio fallback selection'
    assert 'repeatRemaining' not in recitation_service_text and 'boolean continuous=true' not in recitation_service_text, 'Active recitation must not cache repeat/continue settings for the whole playback session'
    assert 'resetRepeat();play();' in recitation_service_text, 'A fresh Play command must start a fresh repeat cycle'
    assert 'private int generation,mediaCommandGeneration;' in recitation_service_text, 'Media-session readiness handoff needs an independent command generation'
    assert 'public void onPlay(){runMediaWhenReady(RecitationService.this::resume);}' in recitation_service_text, 'Media-session Play must wait for app content readiness before resuming'
    assert 'public void onSkipToNext(){runMediaWhenReady(()->move(1));}' in recitation_service_text and 'public void onSkipToPrevious(){runMediaWhenReady(()->move(-1));}' in recitation_service_text, 'Media-session navigation must not be dropped during cold-start content loading'
    assert 'final int token=++mediaCommandGeneration;' in recitation_service_text and 'destroyed||token!=mediaCommandGeneration' in recitation_service_text, 'A superseded media command must not replay after content initialization'
    assert 'String action=intent.getAction();mediaCommandGeneration++;' in recitation_service_text, 'Service commands must supersede any pending MediaSession readiness handoff'
    assert 'AudioManager.ACTION_AUDIO_BECOMING_NOISY' in recitation_service_text, 'Recitation must pause when headphones or another private audio route disconnects'
    assert 'registerReceiver(noisy,noisyFilter,Context.RECEIVER_NOT_EXPORTED)' in recitation_service_text, 'Audio-route receiver must stay private on modern Android'
    assert 'if(noisyReceiverRegistered){unregisterReceiver(noisy);noisyReceiverRegistered=false;}' in recitation_service_text, 'Recitation must release its noisy-route receiver with the Service lifecycle'
    assert 'if(++repeatCompleted<repeatPreference())play();' in recitation_service_text, 'Repeat changes must take effect at the next ayah completion without restarting playback'
    assert 'continuousPreference()&&ayah<app.content.surah(surah).count' in recitation_service_text, 'Continue-mode changes must take effect before advancing to the next ayah'
    audio_controls = java_method('audioControls')
    assert 'if(id.equals(selected))return;' in audio_controls, 'Tapping the already-selected reciter must not restart active playback'
    assert 'if(app.recitationActive)RecitationService.command(this,RecitationService.PLAY,app.recitationSurah,app.recitationAyah);' in audio_controls, 'Changing reciter during active playback must restart the actual playing ayah with the new saved reciter'
    assert 'changing it restarts the current ayah' in audio_controls, 'Reciter UI must explain the live-switch behavior instead of silently showing stale playback'
    assert 'private void move(int delta)' in recitation_service_text and 'ayah=next;resetRepeat();play();' in recitation_service_text, 'Manual recitation navigation must start a fresh repeat cycle'
    assert 'Intent home=new Intent(this,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP)' in recitation_service_text, 'Recitation notification must reuse the existing reader task instead of stacking another MainActivity'
    assert 'if(app!=null&&app.recitationActive)home.putExtra(OPEN_READER,true).putExtra(OPEN_SURAH,surah).putExtra(OPEN_AYAH,ayah);' in recitation_service_text, 'Active recitation notifications must carry the currently playing ayah without misrouting the initial preparing notification'
    assert 'PendingIntent.getActivity(this,10,home,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE)' in recitation_service_text, 'Recitation notification must launch the lifecycle-safe reader intent'
    assert 'PendingIntent.getActivity(this,10,new Intent(this,MainActivity.class)' not in recitation_service_text, 'Do not regress to a duplicate-Activity recitation content intent'
    recitation_intent = java_method('openRecitationIntent', 'boolean')
    assert 'RecitationService.OPEN_READER' in recitation_intent and 'RecitationService.OPEN_SURAH' in recitation_intent and 'RecitationService.OPEN_AYAH' in recitation_intent, 'MainActivity must consume the exact recitation notification target'
    assert 'Dialog previous=activeDialog;activeDialog=null;if(previous!=null)previous.dismiss();' in recitation_intent and 'open(surah,ayah);return true;' in recitation_intent, 'Opening recitation from the notification must close stale sheets and reuse canonical reader navigation'
    assert 'if(openRecitationIntent(getIntent()))return;' in main_activity_text, 'Cold-start notification delivery must open the playing ayah after content initialization'
    assert 'if(openRecitationIntent(intent))return;' in main_activity_text, 'Warm notification delivery must immediately open the playing ayah'
    assert 'private void updateBookmarkButton(FrameLayout button,Glass.Icon icon,boolean saved)' in main_activity_text, 'Reader bookmark state needs one original-control update path'
    assert 'button.setContentDescription(action);button.setTooltipText(action);button.setSelected(saved);' in main_activity_text, 'Bookmark toggles must update accessibility state immediately'
    assert 'source.setMinimumHeight(dp(this,48));source.setFocusable(true);source.setContentDescription("Quran source · Tanzil Project · Uthmani 1.1 · Open source details");source.setTooltipText("Open source details");' in main_activity_text, 'Reader source action must keep a full touch target and explicit accessibility affordance'
    assert 'chip.setMinimumHeight(dp(this,48));' in main_activity_text and 'chip.setFocusable(true);chip.setClickable(true);' in main_activity_text, 'Compact recall actions must keep the Android 48dp minimum touch target and keyboard/TalkBack focusability'
    assert 'item.setMinimumHeight(dp(this,48));' in main_activity_text and 'item.setFocusable(true);item.setClickable(true);' in main_activity_text, 'Recitation download rows must keep the Android 48dp minimum touch target and keyboard/TalkBack focusability'
    assert 'icon.color=saved?Appearance.readable(appearance.accent,appearance.buttonSurface()):appearance.buttonInk();icon.invalidate();' in main_activity_text, 'Saved bookmark feedback must remain readable in the active appearance'
    assert 'FrameLayout bookmark=(FrameLayout)iconButton("bookmark","Save ayah",()->{});' in reader_method and 'updateBookmarkButton(bookmark,bookmarkIcon,pageBookmarks.contains(a.id));' in reader_method, 'Reader bookmark controls must bind their initial saved state'
    assert 'bookmark.setOnClickListener(v->{boolean saved=learning.toggleBookmark(a.id);updateBookmarkButton(bookmark,bookmarkIcon,saved);toast(saved?"Ayah saved":"Bookmark removed");});' in reader_method, 'Reader bookmark toggles must repaint the same control without a full reader rebuild'
    assert 'bar.addView(iconButton("bookmark",pageBookmarks.contains(a.id)?' not in reader_method, 'Do not regress to a stale one-shot bookmark control'
    assert 'boolean hasPrevious=readerStart>1||readerSurah>1,hasNext=readerStart+8<=s.count||readerSurah<114;' in reader_method, 'Reader pager must model Quran boundaries explicitly'
    assert 'previous.setEnabled(hasPrevious)' in reader_method and 'next.setEnabled(hasNext)' in reader_method, 'Reader boundary controls must not remain tappable no-ops'
    assert '"Start of Quran"' in reader_method and '"End of Quran"' in reader_method, 'Reader boundary controls need explicit user feedback'
    move_start = main_activity_text.index('    private boolean moveReaderPage(')
    move_end = main_activity_text.find('\n    private ', move_start + 1)
    move_reader = main_activity_text[move_start:] if move_end < 0 else main_activity_text[move_start:move_end]
    reader_open = java_method('open')
    reader_prefetch = java_method('prefetchReaderNeighbors')
    assert 'private static int readerPageStart(int ayah){return ((Math.max(1,ayah)-1)/8)*8+1;}' in main_activity_text, 'Reader needs one canonical 8-ayah page-grid calculation'
    assert 'int target=Math.max(1,Math.min(content.surah(readerSurah).count,ayah));readerStart=readerPageStart(target);' in reader_open, 'Opening a searched or saved ayah must land on the canonical reader page containing it'
    assert 'String pageId="Q:"+readerSurah+":"+readerStart,anchorId="Q:"+readerSurah+":"+target;' in reader_open, 'Reader target opening must keep page identity separate from the requested ayah anchor'
    assert 'new ReadingPosition(pageId,anchorId,0,0,target==readerStart)' in reader_open, 'Reader target opening must preserve the requested ayah while keeping canonical pagination'
    assert 'readerPageStart(content.surah(previous).count)' in move_reader, 'Previous across a Surah boundary must land on the canonical non-overlapping last page'
    assert 'readerPageStart(content.surah(prior).count)' in reader_prefetch, 'Reader prefetch must target the same previous-Surah page that navigation opens'
    assert 'Ayah anchor=content.ayah(readingPosition.anchorId);' in main_activity_text and 'readerStart=readerPageStart(anchor.number);' in main_activity_text, 'Legacy shifted saved reader pages must migrate from their real visible anchor onto the canonical page grid'
    assert 'new ReadingPosition(canonicalPage,readingPosition.anchorId,readingPosition.codePoint,readingPosition.lineOffsetDp,false)' in main_activity_text, 'Reader-page migration must preserve the saved Unicode anchor and viewport offset'
    assert 'readerSurah=Math.max(1,Math.min(114,readerSurah));' in main_activity_text and 'readerStart=readerPageStart(Math.max(1,Math.min(content.surah(readerSurah).count,readerStart)));' in main_activity_text, 'Reader fallback state without a viewport anchor must still be clamped onto the canonical page grid'
    assert 'lastReaderPageStart' not in main_activity_text and 'count-7' not in move_reader and 'count-7' not in reader_prefetch, 'Do not reintroduce alternate or overlapping reader page-boundary formulas'
    assert 'synchronized Map<String,Recall.State> states(Collection<String> targets)' in learning_store_text, 'Recall single-target flows need the existing targeted state projection'
    assert 'WHERE target IN (' in learning_store_text, 'Targeted Recall state projection must stay bounded to requested targets when the global cache is cold'
    assert 'if(cachedStates!=null){' in learning_store_text and 'Recall.replay(events(Collections.singleton(target))' in learning_store_text and 'cachedStates=Collections.unmodifiableMap(next);' in learning_store_text, 'Appending one learning event must refresh only that target when the global Recall projection cache is warm'
    assert 'surah>0?"Download stopped · Surah "+surah+": "+message:"Download stopped · "+message' in main_activity_text, 'Word-audio batch preflight failures must not display a fabricated Surah 0 coordinate'
    for method in ('enroll', 'review', 'reviewTransition'):
        recall_flow = java_method(method)
        assert 'learning.states()' not in recall_flow, f'{method} must not replay the complete learning history for one Recall target'
        assert 'learning.states(Collections.singleton(' in recall_flow, f'{method} must use the targeted Recall state lookup'
    assert 'metadata==null?store.translation' not in main_activity_text, 'Search cards must not query Hadith translation on the UI thread'
    assert 'metadata==null?store.grades' not in main_activity_text, 'Search cards must not query Hadith grades on the UI thread'
    assert 'hadith&&app.hadith.record(id)==null' not in main_activity_text, 'Saved Hadith shortcut validation must not query SQLite on the UI thread'
    assert 'Loading local translations and grades' in main_activity_text and 'hadithBrowseWorker.submit' in research_pdf_share, 'Hadith comparison preview must load metadata off the UI thread'
    assert permissions == {'android.permission.INTERNET', 'android.permission.SYSTEM_ALERT_WINDOW',
                           'android.permission.FOREGROUND_SERVICE',
                           'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
                           'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
                           'android.permission.POST_NOTIFICATIONS'}
    service = application.find('service')
    assert service.get(android + 'name') == '.AmbientRecallService'
    assert service.get(android + 'exported') == 'false'
    assert service.get(android + 'foregroundServiceType') == 'specialUse'
    assert service.find('property').get(android + 'name') == 'android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'
    media = next(s for s in application.findall('service') if s.get(android + 'name') == '.RecitationService')
    assert media.get(android + 'exported') == 'false' and media.get(android + 'foregroundServiceType') == 'mediaPlayback'
    provider = next(p for p in application.findall('provider') if p.get(android + 'name') == '.ResearchFiles')
    assert provider.get(android + 'exported') == 'false' and provider.get(android + 'grantUriPermissions') == 'true'
    assert provider.get(android + 'authorities') == '${applicationId}.research', 'Research PDF authority must follow the final applicationId for every build variant'
    sources = sorted((ROOT / 'core/src/main/java').rglob('*.java'))
    tests = sorted((ROOT / 'core/src/test/java').rglob('*.java'))
    with tempfile.TemporaryDirectory(prefix='aaris-check-') as scratch:
        # Always exercise the Hadith builder against a tiny synthetic fixture, even when the
        # real corpus is not installed. This catches schema/placeholder/search-column drift.
        fixture_source = Path(scratch) / 'hadith-source'
        (fixture_source / 'records').mkdir(parents=True)
        (fixture_source / 'LICENSES').mkdir()
        fixture_records = fixture_source / 'records' / 'fixture.jsonl'
        fixture_records.write_bytes((ROOT / 'source-vault/hadith/records.example.jsonl').read_bytes())
        fixture_permission = fixture_source / 'LICENSES' / 'PERMISSION.txt'
        fixture_permission.write_text('Engineering test fixture only; not a distributable Hadith corpus.\n')
        fixture_manifest = {
            'pack_id': 'hadith-builder-fixture',
            'content_version': '0',
            'source_name': 'Aaris synthetic fixture',
            'source_version': 'fixture-1',
            'redistribution_basis': 'Synthetic engineering fixture authored in this repository.',
            'license_files': ['LICENSES/PERMISSION.txt'],
            'files': {
                'records/fixture.jsonl': hashlib.sha256(fixture_records.read_bytes()).hexdigest(),
                'LICENSES/PERMISSION.txt': hashlib.sha256(fixture_permission.read_bytes()).hexdigest(),
            },
        }
        (fixture_source / 'manifest.json').write_text(json.dumps(fixture_manifest, indent=2) + '\n')
        fixture_output = Path(scratch) / 'hadith-fixture' / 'hadith.sqlite'
        subprocess.run([
            sys.executable, str(ROOT / 'tools/build_hadith.py'),
            '--source', str(fixture_source), '--output', str(fixture_output)
        ], check=True, cwd=ROOT, stdout=subprocess.DEVNULL)
        fixture_generated = json.loads((fixture_output.parent / 'hadith-manifest.json').read_text())
        assert fixture_generated['schema_version'] == 2
        assert fixture_generated['records'] == 1
        fixture_db = sqlite3.connect(f'file:{fixture_output}?mode=ro', uri=True)
        assert fixture_db.execute('PRAGMA user_version').fetchone()[0] == 2
        columns = {row[1] for row in fixture_db.execute('PRAGMA table_info(hadith)')}
        assert {'search_ar', 'search_latin', 'source_sha256', 'record_kind'} <= columns
        assert fixture_db.execute('SELECT count(*) FROM hadith').fetchone()[0] == 1
        assert fixture_db.execute('SELECT count(*) FROM hadith_fts').fetchone()[0] == 1
        assert fixture_db.execute("SELECT count(*) FROM hadith_fts WHERE hadith_fts MATCH 'تجريبي'").fetchone()[0] == 1
        assert fixture_db.execute("SELECT count(*) FROM search_token WHERE token='تجريبي'").fetchone()[0] == 1
        assert fixture_db.execute('SELECT count(*) FROM grade_assertion').fetchone()[0] == 1
        assert {row[1] for row in fixture_db.execute('PRAGMA table_info(search_context)')} >= {'hadith_id','language','kind','text','roman','source_ref'}
        assert not fixture_db.execute('PRAGMA foreign_key_check').fetchall()
        fixture_db.close()

        classes = Path(scratch) / 'classes'
        classes.mkdir()
        subprocess.run([java, 'com.sun.tools.javac.Main', '--release', '17', '-encoding', 'UTF-8',
                        '-d', str(classes), *map(str, sources + tests)], check=True)
        subprocess.run([java, '-cp', str(classes), 'com.aaris.quran.core.CoreChecks'], check=True, cwd=ROOT)
        subprocess.run([sys.executable, str(ROOT / 'tools/check_hadith_search.py'), '--classes', str(classes)], check=True, cwd=ROOT)
        corpus = Path(scratch) / 'corpus.tsv'
        encode = lambda value: base64.b64encode(value.encode()).decode()
        # Match ContentStore's runtime search document order explicitly. Aggregate input order is
        # undefined without an aggregate ORDER BY and older Android SQLite versions cannot rely on
        # newer group_concat ordering syntax.
        word_hints, word_sounds = {}, {}
        for aid, en, hi, ur, translit in db.execute(
                'SELECT ayah_id,gloss_en,gloss_hi,gloss_ur,transliteration '
                'FROM word ORDER BY ayah_id,position,start_cp'):
            hints = word_hints.setdefault(aid, [])
            hints.extend(value for value in (en, hi, ur, translit) if value)
            if translit:
                word_sounds.setdefault(aid, []).append(translit)
        with corpus.open('w') as out:
            for aid, surah, number, ordinal, arabic in db.execute(
                    'SELECT id,surah,number,ordinal,arabic FROM ayah ORDER BY ordinal'):
                hints = ' '.join(word_hints.get(aid, []))
                translated = translations.get(aid, '')
                if translated:
                    hints = (hints + ' ' + translated).strip()
                sounds = ' '.join(word_sounds.get(aid, []))
                out.write(f'{surah}\t{number}\t{ordinal}\t{encode(arabic)}\t{encode(hints)}\t{encode(sounds)}\n')
        subprocess.run([java, '-Xmx256m', '-cp', str(classes), 'com.aaris.quran.core.CorpusChecks', str(corpus)], check=True, cwd=ROOT)
        generated = Path(scratch) / 'generated'
        generated.mkdir()
        if args.aapt2:
            resources = Path(scratch) / 'resources.zip'
            manifest_tree = ET.parse(ROOT / 'app/src/main/AndroidManifest.xml')
            manifest_tree.getroot().set('package', 'com.aaris.quran')
            # check.py links the raw source manifest without Gradle's manifest merger, so mirror
            # applicationId placeholder expansion before asking aapt2 to validate the manifest.
            for node in manifest_tree.getroot().iter():
                authority = node.get(android + 'authorities')
                if authority:
                    node.set(android + 'authorities', authority.replace('${applicationId}', 'com.aaris.quran'))
            manifest_path = Path(scratch) / 'AndroidManifest.xml'
            ET.register_namespace('android', 'http://schemas.android.com/apk/res/android')
            manifest_tree.write(manifest_path, encoding='utf-8', xml_declaration=True)
            subprocess.run([str(args.aapt2), 'compile', '--dir', str(ROOT / 'app/src/main/res'), '-o', str(resources)], check=True)
            subprocess.run([str(args.aapt2), 'link', '--manifest', str(manifest_path), '-I', str(args.android_jar),
                            '--min-sdk-version', '26', '--target-sdk-version', '35',
                            '--java', str(generated), '-o', str(Path(scratch) / 'resources.ap_'), str(resources)], check=True)
            print('Android resource compile and manifest link: PASS (not an installable APK)')
        if args.android_jar:
            if not args.aapt2:
                raise SystemExit('--aapt2 is needed with --android-jar to generate actual resource IDs.')
            app = sorted((ROOT / 'app/src/main/java').rglob('*.java'))
            resources_java = sorted(generated.rglob('*.java'))
            subprocess.run([java, 'com.sun.tools.javac.Main', '--release', '17', '-encoding', 'UTF-8',
                            '-cp', str(args.android_jar), '-d', str(classes),
                            *map(str, sources + app + resources_java)], check=True)
            print('Android Java compile: PASS (API jar; not a device or APK test)')
    hadith_state = 'verified local Hadith pack' if hadith_pack.exists() else 'no Hadith pack bundled'
    print('Content hashes, 6,236 ayahs, 77,881 word ranges, startup manifest, exact isolated-word Surah audio boundary and '+hadith_state+': PASS')


if __name__ == '__main__':
    main()
