#!/usr/bin/env python3
"""One-time maintainer capture of official HadeethEnc XLSX snapshots.

This tool is intentionally NOT part of the Android/Gradle build. It downloads source bytes only
for maintainers, validates the official host/version/XLSX container, writes all languages
transactionally, and records SHA-256 provenance. Runtime builds consume only checked-in snapshots.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import tempfile
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path
from urllib.parse import urlparse
from zipfile import ZipFile, BadZipFile

from hadeethenc_xlsx import parse_workbook

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "source-vault" / "hadith" / "hadeethenc" / "current"
OFFICIAL_HOST = "hadeethenc.com"
LANGUAGES = {
    "ar": {"name": "Arabic", "minimum_version": "1.7.0"},
    "en": {"name": "English", "minimum_version": "1.25.0"},
    "ur": {"name": "Urdu", "minimum_version": "1.36.0"},
    "hi": {"name": "Hindi", "minimum_version": "1.59.0"},
}
VERSION_RE = re.compile(r"HadeethEnc\.com_([a-z]+)-v([0-9]+(?:\.[0-9]+)*)\.xlsx$", re.I)


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(language: str, target: Path) -> dict:
    source = f"https://hadeethenc.com/browse/download/{language}"
    last = None
    for attempt in range(6):
        request = urllib.request.Request(
            source,
            headers={
                "User-Agent": "AarisQuranSourceVault/1.0 (+https://github.com/warishakhan3548-hash/updating-repository)",
                "Accept": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,*/*;q=0.8",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                final_url = response.geturl()
                parsed = urlparse(final_url)
                if parsed.scheme != "https" or parsed.hostname != OFFICIAL_HOST:
                    raise RuntimeError(f"Refusing non-official HadeethEnc redirect: {final_url}")
                match = VERSION_RE.search(parsed.path)
                if not match or match.group(1).lower() != language:
                    raise RuntimeError(f"Could not prove HadeethEnc language/version from {final_url}")
                version = match.group(2)
                minimum = LANGUAGES[language]["minimum_version"]
                if version_tuple(version) < version_tuple(minimum):
                    raise RuntimeError(
                        f"Refusing stale HadeethEnc {language} v{version}; expected at least v{minimum}"
                    )
                with target.open("wb") as out:
                    shutil.copyfileobj(response, out)
                break
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code != 429 or attempt == 5:
                raise
            retry = exc.headers.get("Retry-After", "").strip()
            delay = int(retry) if retry.isdigit() else min(60, 2 ** (attempt + 1))
            time.sleep(delay)
    else:
        raise last or RuntimeError("HadeethEnc download failed")

    if target.stat().st_size < 1024:
        raise RuntimeError(f"Suspiciously small HadeethEnc workbook: {target}")
    try:
        with ZipFile(target) as zf:
            required = {"xl/workbook.xml", "xl/worksheets/sheet1.xml"}
            missing = required - set(zf.namelist())
            if missing:
                raise RuntimeError(f"Invalid XLSX; missing {sorted(missing)}")
    except BadZipFile as exc:
        raise RuntimeError(f"Invalid XLSX archive for {language}") from exc

    parsed = parse_workbook(target, language)
    if parsed.get("version") and parsed["version"] != version:
        raise RuntimeError(
            f"HadeethEnc metadata version mismatch for {language}: "
            f"{parsed['version']} != {version}"
        )

    return {
        "language": language,
        "name": LANGUAGES[language]["name"],
        "version": version,
        "source_url": source,
        "download_url": final_url,
        "sha256": sha256(target),
        "bytes": target.stat().st_size,
        "records": len(parsed["records"]),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--languages", nargs="+", default=list(LANGUAGES))
    args = parser.parse_args()
    languages = [value.lower() for value in args.languages]
    if len(languages) != len(set(languages)) or any(code not in LANGUAGES for code in languages):
        raise SystemExit("Languages must be unique members of: " + ", ".join(LANGUAGES))

    DEST.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hadeethenc-", dir=DEST.parent) as scratch:
        scratch = Path(scratch)
        records = []
        for language in languages:
            temp = scratch / f"{language}.xlsx"
            records.append(fetch(language, temp))

        # Only publish after every requested language succeeds and validates.
        for record in records:
            shutil.move(str(scratch / f"{record['language']}.xlsx"), DEST / f"{record['language']}.xlsx")
        manifest = {
            "schema": 1,
            "provider": "HadeethEnc.com",
            "captured_on": date.today().isoformat(),
            "terms_url": "https://hadeethenc.com/en",
            "policy_url": "https://github.com/IslamHouse-API/multilingual-quran-hadith-islamic-content-database-api-hub",
            "runtime_network_required": False,
            "content_policy": "Original source text is stored unchanged; source/version must stay visible and newer official versions must replace the active snapshot.",
            "languages": records,
        }
        (DEST / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
