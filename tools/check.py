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
    splash_styles = (ROOT / 'app/src/main/res/values-v31/styles.xml').read_text(encoding='utf-8')
    splash_icon = (ROOT / 'app/src/main/res/drawable/ic_quran_splash.xml').read_text(encoding='utf-8')
    assert 'name="AppLaunchTheme"' in styles_text
    assert 'android:windowSplashScreenAnimatedIcon' in splash_styles
    assert '@drawable/ic_quran_splash' in splash_styles
    assert '<vector' in splash_icon and '#D8C28A' in splash_icon
    permissions = {p.get(android + 'name') for p in android_manifest.findall('uses-permission')}
    java_sources = '\n'.join(p.read_text(encoding='utf-8') for p in (ROOT / 'app/src/main/java').rglob('*.java'))
    assert 'https://sunnah.com/' not in java_sources, 'Runtime Hadith website dependency returned'

    # Translation speech must recover automatically when Android removes or renames a saved offline voice.
    translation_speech_text = (ROOT / 'app/src/main/java/com/aaris/quran/TranslationSpeech.java').read_text(encoding='utf-8')
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
    assert 'private void normalizeEditingLayer()' in appearance_studio_text and 'if(layer==5&&!style.gradient){layer=0;invalidateEditorColor();}' in appearance_studio_text, 'Appearance undo/redo must not leave a hidden gradient layer selected'
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
    assert 'appearance.effectiveCardOpacity()' in glass_text and 'appearance.effectiveBorderStrength()' in glass_text
    assert 'cachedGradientAngle!=appearance.gradientAngle' in glass_text
    assert 'setLetterSpacing(' not in quran_text and 'setLetterSpacing(' not in arabic_text, 'Do not alter Quran Arabic tracking/shaping'

    # Large Hadith-pack browsing must never regress to synchronous SQLite reads on the Android UI thread.
    main_activity_text = (ROOT / 'app/src/main/java/com/aaris/quran/MainActivity.java').read_text(encoding='utf-8')
    quran_app_text = (ROOT / 'app/src/main/java/com/aaris/quran/QuranApp.java').read_text(encoding='utf-8')
    learning_store_text = (ROOT / 'app/src/main/java/com/aaris/quran/LearningStore.java').read_text(encoding='utf-8')
    recitation_downloads_text = (ROOT / 'app/src/main/java/com/aaris/quran/RecitationDownloads.java').read_text(encoding='utf-8')
    assert 'private void updateHighContrast(boolean enabled)' in main_activity_text and 'contrast.setOnCheckedChangeListener((b,v)->updateHighContrast(v));' in main_activity_text, 'High-contrast setting must use the live surface refresh path'
    assert 'highContrast=enabled;learning.set("contrast",""+enabled);\n        show();settings();' in main_activity_text, 'High-contrast changes must rebuild both the underlying screen and the open settings sheet immediately'
    assert 'hadithBrowseWorker=worker("hadith-browse")' in quran_app_text, 'Missing dedicated Hadith browse worker'
    assert 'recitationStatusWorker=worker("recitation-status")' in quran_app_text, 'Recitation download status scans need a dedicated background worker'
    def java_method(name):
        marker = f'    private void {name}('
        start = main_activity_text.index(marker)
        end = main_activity_text.find('\n    private ', start + len(marker))
        return main_activity_text[start:] if end < 0 else main_activity_text[start:end]
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
    assert 'list.removeView(more)' not in hadith_search_batch and 'loadHadithSearch(q,response.nextOffset,generation,list,status,more)' in hadith_search_batch, 'Hadith load-more taps must not destroy their only retry affordance before success'
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
    assert 'generation==wordAudioPlayGeneration' in play_flow and 'app.recitationDownloads==downloads' in play_flow, 'Async reciter verification must reject stale playback results'
    assert 'reciter.equals(verifiedReciter)' in play_flow, 'Changing reciter while verification is running must invalidate the old result'
    assert 'wordFallbackReady&&(verifiedReciter==null||!reciter.equals(verifiedReciter))' in play_flow, 'Reciter verification should run only when it can affect word-audio fallback selection'
    assert 'boolean hasPrevious=readerStart>1||readerSurah>1,hasNext=readerStart+8<=s.count||readerSurah<114;' in reader_method, 'Reader pager must model Quran boundaries explicitly'
    assert 'previous.setEnabled(hasPrevious)' in reader_method and 'next.setEnabled(hasNext)' in reader_method, 'Reader boundary controls must not remain tappable no-ops'
    assert '"Start of Quran"' in reader_method and '"End of Quran"' in reader_method, 'Reader boundary controls need explicit user feedback'
    move_start = main_activity_text.index('    private boolean moveReaderPage(')
    move_end = main_activity_text.find('\n    private ', move_start + 1)
    move_reader = main_activity_text[move_start:] if move_end < 0 else main_activity_text[move_start:move_end]
    reader_prefetch = java_method('prefetchReaderNeighbors')
    assert 'private static int lastReaderPageStart(int ayahCount){return ((Math.max(1,ayahCount)-1)/8)*8+1;}' in main_activity_text, 'Reader needs one canonical last-page boundary calculation'
    assert 'lastReaderPageStart(content.surah(previous).count)' in move_reader, 'Previous across a Surah boundary must land on the canonical non-overlapping last page'
    assert 'lastReaderPageStart(content.surah(prior).count)' in reader_prefetch, 'Reader prefetch must target the same previous-Surah page that navigation opens'
    assert 'count-7' not in move_reader and 'count-7' not in reader_prefetch, 'Do not reintroduce overlapping previous-Surah reader pages'
    assert 'synchronized Map<String,Recall.State> states(Collection<String> targets)' in learning_store_text, 'Recall single-target flows need the existing targeted state projection'
    assert 'WHERE target IN (' in learning_store_text, 'Targeted Recall state projection must stay bounded to requested targets when the global cache is cold'
    for method in ('enroll', 'review', 'reviewTransition'):
        recall_flow = java_method(method)
        assert 'learning.states()' not in recall_flow, f'{method} must not replay the complete learning history for one Recall target'
        assert 'learning.states(Collections.singleton(' in recall_flow, f'{method} must use the targeted Recall state lookup'
    assert 'metadata==null?store.translation' not in main_activity_text, 'Search cards must not query Hadith translation on the UI thread'
    assert 'metadata==null?store.grades' not in main_activity_text, 'Search cards must not query Hadith grades on the UI thread'
    assert 'hadith&&app.hadith.record(id)==null' not in main_activity_text, 'Saved Hadith shortcut validation must not query SQLite on the UI thread'
    assert 'Loading local translations and grades' in main_activity_text and 'hadithBrowseWorker.submit' in java_method('shareResearch'), 'Hadith comparison preview must load metadata off the UI thread'
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
