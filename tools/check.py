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
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    if not __debug__:
        raise SystemExit('Run checks without -O; integrity assertions must be enabled.')
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
        hdb = sqlite3.connect(f'file:{hadith_pack}?mode=ro', uri=True)
        assert hdb.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert hdb.execute('PRAGMA user_version').fetchone()[0] == 2
        assert hdb.execute('SELECT count(*) FROM collection').fetchone()[0] == hmanifest['collections']
        assert hdb.execute('SELECT count(*) FROM hadith').fetchone()[0] == hmanifest['records']
        assert hdb.execute('SELECT count(*) FROM hadith_fts').fetchone()[0] == hmanifest['records']
        assert not hdb.execute('PRAGMA foreign_key_check').fetchall()
        for arabic, expected in hdb.execute('SELECT arabic,source_sha256 FROM hadith'):
            assert hashlib.sha256(arabic.encode()).hexdigest() == expected
        hdb.close()
    android = '{http://schemas.android.com/apk/res/android}'
    android_manifest = ET.parse(ROOT / 'app/src/main/AndroidManifest.xml').getroot()
    application = android_manifest.find('application')
    assert application.get(android + 'name') == '.QuranApp', 'Missing startup wiring'
    permissions = {p.get(android + 'name') for p in android_manifest.findall('uses-permission')}
    java_sources = '\n'.join(p.read_text(encoding='utf-8') for p in (ROOT / 'app/src/main/java').rglob('*.java'))
    assert 'https://sunnah.com/' not in java_sources, 'Runtime Hadith website dependency returned'
    assert permissions == {'android.permission.INTERNET', 'android.permission.SYSTEM_ALERT_WINDOW',
                           'android.permission.FOREGROUND_SERVICE',
                           'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
                           'android.permission.POST_NOTIFICATIONS'}
    service = application.find('service')
    assert service.get(android + 'name') == '.AmbientRecallService'
    assert service.get(android + 'exported') == 'false'
    assert service.get(android + 'foregroundServiceType') == 'specialUse'
    assert service.find('property').get(android + 'name') == 'android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'
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
        assert fixture_db.execute('SELECT count(*) FROM grade_assertion').fetchone()[0] == 1
        assert not fixture_db.execute('PRAGMA foreign_key_check').fetchall()
        fixture_db.close()

        classes = Path(scratch) / 'classes'
        classes.mkdir()
        subprocess.run([java, 'com.sun.tools.javac.Main', '--release', '17', '-encoding', 'UTF-8',
                        '-d', str(classes), *map(str, sources + tests)], check=True)
        subprocess.run([java, '-cp', str(classes), 'com.aaris.quran.core.CoreChecks'], check=True, cwd=ROOT)
        corpus = Path(scratch) / 'corpus.tsv'
        encode = lambda value: base64.b64encode(value.encode()).decode()
        with corpus.open('w') as out:
            for surah, number, ordinal, arabic, hints in db.execute('''
                    SELECT a.surah,a.number,a.ordinal,a.arabic,
                    group_concat(COALESCE(w.gloss_en,'')||' '||COALESCE(w.gloss_hi,'')||' '||
                    COALESCE(w.gloss_ur,'')||' '||COALESCE(w.transliteration,''),' ')
                    FROM ayah a LEFT JOIN word w ON w.ayah_id=a.id GROUP BY a.id ORDER BY a.ordinal'''):
                out.write(f'{surah}\t{number}\t{ordinal}\t{encode(arabic)}\t{encode(hints or "")}\n')
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
