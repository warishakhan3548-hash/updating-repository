#!/usr/bin/env python3
"""Offline integrity + JVM regression checks; optionally compile Android sources.

Usage: python3 tools/check.py [--android-jar /path/to/platform/android.jar]
No APK, CI workflow, emulator or downloaded testing dependency is required.
"""
import argparse
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
    parser = argparse.ArgumentParser()
    parser.add_argument('--android-jar', type=Path)
    args = parser.parse_args()
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
    for text, digest in db.execute('SELECT arabic,sha256 FROM ayah'):
        assert hashlib.sha256(text.encode()).hexdigest() == digest
    for text, start, end, word in db.execute(
            'SELECT a.arabic,w.start_cp,w.end_cp,w.arabic FROM word w JOIN ayah a ON a.id=w.ayah_id'):
        assert text[start:end] == word, 'Word/source offset mismatch'
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
    android = '{http://schemas.android.com/apk/res/android}'
    application = ET.parse(ROOT / 'app/src/main/AndroidManifest.xml').getroot().find('application')
    assert application.get(android + 'name') == '.QuranApp', 'Missing startup wiring'
    sources = sorted((ROOT / 'core/src/main/java').rglob('*.java'))
    tests = sorted((ROOT / 'core/src/test/java').rglob('*.java'))
    with tempfile.TemporaryDirectory(prefix='aaris-check-') as scratch:
        classes = Path(scratch) / 'classes'
        classes.mkdir()
        subprocess.run([java, 'com.sun.tools.javac.Main', '--release', '17', '-encoding', 'UTF-8',
                        '-d', str(classes), *map(str, sources + tests)], check=True)
        subprocess.run([java, '-cp', str(classes), 'com.aaris.quran.core.CoreChecks'], check=True, cwd=ROOT)
        if args.android_jar:
            app = sorted((ROOT / 'app/src/main/java').rglob('*.java'))
            subprocess.run([java, 'com.sun.tools.javac.Main', '--release', '17', '-encoding', 'UTF-8',
                            '-cp', str(args.android_jar), '-d', str(classes),
                            *map(str, sources + app)], check=True)
            print('Android Java compile: PASS (API jar; not a device or APK test)')
    print('Content hashes, 6,236 ayahs, 77,881 word ranges and startup manifest: PASS')


if __name__ == '__main__':
    main()
