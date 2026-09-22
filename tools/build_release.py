#!/usr/bin/env python3
"""Build this dependency-free native app with the official Android SDK, without Gradle downloads.

Produces a signed, non-debuggable release APK, never an AAB. Secrets stay outside the repository.
The conventional Gradle build remains supported; this bounded route refuses extra dependencies.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ANDROID = '{http://schemas.android.com/apk/res/android}'


def run(args, capture=False):
    return subprocess.run(list(map(str, args)), check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(65536), b''):
            result.update(chunk)
    return result.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--android-jar', type=Path, required=True)
    p.add_argument('--build-tools', type=Path, required=True)
    p.add_argument('--keystore', type=Path, required=True)
    p.add_argument('--alias', required=True)
    p.add_argument('--password-file', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    java = Path(os.environ.get('JAVA_HOME', '/usr/lib/jvm/java-17-openjdk-amd64')) / 'bin/java'
    aapt = args.build_tools / 'aapt2'
    align = args.build_tools / 'zipalign'
    d8 = args.build_tools / 'lib/d8.jar'
    signer = args.build_tools / 'lib/apksigner.jar'
    for file in [java, aapt, align, d8, signer, args.android_jar, args.keystore, args.password_file]:
        if not file.is_file():
            raise SystemExit(f'Required build input missing: {file.name}')
    if args.output.suffix != '.apk':
        raise SystemExit('Output must be an APK')
    if args.output.exists():
        raise SystemExit('Choose a new output path; an existing APK will not be overwritten')
    gradle = (ROOT / 'app/build.gradle').read_text()
    dependencies = re.search(r'dependencies\s*\{([^}]+)\}', gradle)
    if not dependencies or re.sub(r'\s+', '', dependencies[1]) != "implementationproject(':core')":
        raise SystemExit('Dependencies changed. Use Gradle or explicitly update this builder.')
    if list((ROOT / 'app/src').rglob('*.kt')) or list((ROOT / 'app/src/main').rglob('*.so')):
        raise SystemExit('Kotlin/native dependencies require the Gradle build')
    def setting(name, quoted=False):
        pattern = rf"\b{name}\s+'([^']+)'" if quoted else rf'\b{name}\s+(\d+)'
        found = re.search(pattern, gradle)
        if not found:
            raise SystemExit(f'Dynamic {name} requires the Gradle build')
        return found[1]
    app_id = setting('applicationId', True)
    version_name, version_code = setting('versionName', True), setting('versionCode')
    min_sdk, target_sdk = setting('minSdk'), setting('targetSdk')
    run(['python3', ROOT / 'tools/build_content.py'])
    assets = ROOT / 'app/src/main/assets'
    content = json.loads((assets / 'content-manifest.json').read_text())
    if digest(assets / 'quran.sqlite') != content['sqlite_sha256']:
        raise SystemExit('Content pack differs from its manifest')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='aaris-release-') as temporary:
        work = Path(temporary)
        manifest = ET.parse(ROOT / 'app/src/main/AndroidManifest.xml')
        manifest.getroot().set('package', app_id)
        application = manifest.getroot().find('application')
        application.set(ANDROID + 'debuggable', 'false')
        application.set(ANDROID + 'testOnly', 'false')
        ET.register_namespace('android', 'http://schemas.android.com/apk/res/android')
        manifest_file = work / 'AndroidManifest.xml'
        manifest.write(manifest_file, encoding='utf-8', xml_declaration=True)
        resources, unsigned, aligned = work / 'resources.zip', work / 'unsigned.apk', work / 'aligned.apk'
        generated, classes, dex = work / 'generated', work / 'classes', work / 'dex'
        for folder in [generated, classes, dex]:
            folder.mkdir()
        run([aapt, 'compile', '--dir', ROOT / 'app/src/main/res', '-o', resources])
        run([aapt, 'link', '--manifest', manifest_file, '-I', args.android_jar, '-A', assets,
             '--min-sdk-version', min_sdk, '--target-sdk-version', target_sdk,
             '--version-code', version_code, '--version-name', version_name,
             '--java', generated, '-o', unsigned, resources])
        sources = sorted((ROOT / 'core/src/main/java').rglob('*.java')) + sorted((ROOT / 'app/src/main/java').rglob('*.java')) + sorted(generated.rglob('*.java'))
        run([java, 'com.sun.tools.javac.Main', '--release', '17', '-encoding', 'UTF-8',
             '-g:source,lines', '-cp', args.android_jar, '-d', classes, *sources])
        archive = work / 'classes.jar'
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
            for file in sorted(classes.rglob('*.class')):
                entry = zipfile.ZipInfo(file.relative_to(classes).as_posix(), (2000, 1, 1, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(entry, file.read_bytes())
        run([java, '-cp', d8, 'com.android.tools.r8.D8', '--release', '--min-api', min_sdk,
             '--lib', args.android_jar, '--output', dex, archive])
        dex_files = sorted(dex.glob('classes*.dex'))
        if not dex_files:
            raise SystemExit('No Android bytecode produced')
        with zipfile.ZipFile(unsigned, 'a', zipfile.ZIP_DEFLATED) as z:
            for file in dex_files:
                z.write(file, file.name)
        run([align, '-P', '16', '-f', '4', unsigned, aligned])
        signed = work / 'signed-release.apk'
        run([java, '-jar', signer, 'sign', '--ks', args.keystore, '--ks-key-alias', args.alias,
             '--ks-pass', 'file:' + str(args.password_file),
             '--v1-signing-enabled', 'true', '--v2-signing-enabled', 'true', '--v3-signing-enabled', 'true',
             '--v4-signing-enabled', 'false', '--out', signed, aligned])
        verification = run([java, '-jar', signer, 'verify', '--verbose', '--print-certs', signed], capture=True)
        if 'Android Debug' in verification or 'Verified using v2 scheme (APK Signature Scheme v2): true' not in verification:
            raise SystemExit('Release signature verification failed')
        run([align, '-c', '-P', '16', '4', signed], capture=True)
        badging = run([aapt, 'dump', 'badging', signed], capture=True)
        sdk_line = re.search(rf"(?m)^(?:minSdkVersion|sdkVersion):'{min_sdk}'$", badging)
        if 'application-debuggable' in badging or f"name='{app_id}'" not in badging or sdk_line is None:
            raise SystemExit('Unexpected package identity/debug/SDK flags')
        with zipfile.ZipFile(signed) as z:
            required = ['AndroidManifest.xml', 'resources.arsc', 'classes.dex', 'assets/quran.sqlite', 'assets/fonts/AmiriQuran.ttf']
            if z.testzip() is not None or any(name not in z.namelist() for name in required):
                raise SystemExit('APK payload is incomplete')
            if hashlib.sha256(z.read('assets/quran.sqlite')).hexdigest() != content['sqlite_sha256']:
                raise SystemExit('APK scripture pack changed during packaging')
        shutil.copyfile(signed, args.output)
    report = {
        'application_id': app_id, 'version_name': version_name, 'version_code': int(version_code),
        'min_sdk': int(min_sdk), 'target_sdk': int(target_sdk), 'variant': 'release',
        'debuggable': False, 'aab_built': False, 'apk_sha256': digest(args.output),
        'apk_bytes': args.output.stat().st_size, 'quran_pack_sha256': content['sqlite_sha256'],
        'source_commit': run(['git', '-C', ROOT, 'rev-parse', 'HEAD'], capture=True).strip(),
        'source_tree': run(['git', '-C', ROOT, 'rev-parse', 'HEAD^{tree}'], capture=True).strip(),
        'source_tree_dirty': bool(run(['git', '-C', ROOT, 'status', '--porcelain'], capture=True).strip()),
        'builder': 'Official SDK aapt2 + javac + D8 --release + zipalign + apksigner',
        'signature_verification': verification.strip().splitlines(),
        'apk_badging': badging.strip().splitlines(),
        'tools_sha256': {file.name: digest(file) for file in [aapt, d8, signer, args.android_jar]},
        'not_tested': ['Android device/emulator launch', 'physical overlay/RTL layout', 'Android PDF rendering/document-provider integration'],
    }
    args.output.with_suffix('.build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['application_id', 'version_name', 'apk_bytes', 'apk_sha256', 'source_tree_dirty']}, indent=2))


if __name__ == '__main__':
    main()
