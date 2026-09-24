#!/usr/bin/env python3
"""Run the actual Android HadithStore on a host SQLite adapter, without building an APK.

Pass a local directory containing sqlite-jdbc, org.json and slf4j-api JARs. This script never
downloads dependencies and none of these host-only libraries enter the app. Not a device test.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dependencies', required=True, type=Path)
    args = parser.parse_args()
    lock = json.loads((ROOT / 'tools/host-search/dependencies.json').read_text())
    jars = []
    for artifact in lock['artifacts']:
        jar = args.dependencies.resolve() / artifact['file']
        if not jar.is_file() or hashlib.sha256(jar.read_bytes()).hexdigest() != artifact['sha256']:
            raise SystemExit(f"Missing/wrong host-test dependency: {artifact['file']}. See tools/host-search/dependencies.json; no downloads are performed.")
        jars.append(jar)
    sources = list((ROOT / 'core/src/main/java').rglob('*.java'))
    sources += list((ROOT / 'tools/host-search').rglob('*.java'))
    sources.append(ROOT / 'app/src/main/java/com/aaris/quran/HadithStore.java')
    with tempfile.TemporaryDirectory(prefix='aaris-search-runtime-') as temp:
        scratch = Path(temp)
        classes, files = scratch / 'classes', scratch / 'files'
        classes.mkdir(); files.mkdir()
        deps = ':'.join(map(str, jars))
        subprocess.run(['java', 'com.sun.tools.javac.Main', '--release', '17', '-encoding', 'UTF-8',
                        '-cp', deps, '-d', str(classes), *map(str, sources)], check=True)
        subprocess.run(['java', '-Xmx256m', '-cp', str(classes) + ':' + deps,
                        'com.aaris.quran.HadithRuntimeChecks', str(ROOT / 'app/src/main/assets'),
                        str(files)], check=True, timeout=90)


if __name__ == '__main__':
    main()
