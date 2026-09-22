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
    android = '{http://schemas.android.com/apk/res/android}'
    android_manifest = ET.parse(ROOT / 'app/src/main/AndroidManifest.xml').getroot()
    application = android_manifest.find('application')
    assert application.get(android + 'name') == '.QuranApp', 'Missing startup wiring'
    permissions = {p.get(android + 'name') for p in android_manifest.findall('uses-permission')}
    assert permissions == {'android.permission.SYSTEM_ALERT_WINDOW', 'android.permission.FOREGROUND_SERVICE',
                           'android.permission.FOREGROUND_SERVICE_SPECIAL_USE', 'android.permission.POST_NOTIFICATIONS'}
    service = application.find('service')
    assert service.get(android + 'name') == '.AmbientRecallService'
    assert service.get(android + 'exported') == 'false'
    assert service.get(android + 'foregroundServiceType') == 'specialUse'
    assert service.find('property').get(android + 'name') == 'android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'
    sources = sorted((ROOT / 'core/src/main/java').rglob('*.java'))
    tests = sorted((ROOT / 'core/src/test/java').rglob('*.java'))
    with tempfile.TemporaryDirectory(prefix='aaris-check-') as scratch:
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
    print('Content hashes, 6,236 ayahs, 77,881 word ranges and startup manifest: PASS')


if __name__ == '__main__':
    main()
