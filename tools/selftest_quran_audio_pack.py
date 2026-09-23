#!/usr/bin/env python3
"""Offline synthetic self-test for the Quran audio pack builder/verifier.

No network and no real Quran audio are used. The test creates a tiny canonical SQLite database and
three fake Ogg-like clips, runs prepare_quran_audio.py, verifies the result, corrupts one packed
clip, and requires check_quran_audio.py to reject the corruption.
"""
import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]


def run(*args,expect_ok=True):
    result=subprocess.run([str(x) for x in args],cwd=ROOT,text=True,capture_output=True)
    if expect_ok and result.returncode!=0:
        raise SystemExit(f"Command failed unexpectedly:\n{result.stdout}\n{result.stderr}")
    if not expect_ok and result.returncode==0:
        raise SystemExit("Corruption was not rejected by Quran audio verifier")
    return result


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_clip(path,seed):
    path.parent.mkdir(parents=True,exist_ok=True)
    # The packer/verifier only need an Ogg container signature for structural self-test.
    path.write_bytes(b"OggS"+bytes([seed])*64)


def main():
    with tempfile.TemporaryDirectory(prefix="aaris-audio-selftest-") as tmp:
        tmp=Path(tmp)
        db_path=tmp/"quran.sqlite"
        db=sqlite3.connect(db_path)
        db.executescript("""
        CREATE TABLE word(
          id TEXT PRIMARY KEY,
          ayah_id TEXT NOT NULL,
          position INTEGER NOT NULL,
          mapping_state TEXT NOT NULL
        );
        """)
        db.executemany("INSERT INTO word VALUES(?,?,?,?)",[
            ("Q:1:1:W:1","Q:1:1",1,"SOURCE_ALIGNED"),
            ("Q:1:1:W:2","Q:1:1",2,"SOURCE_ALIGNED"),
            ("Q:2:1:W:1","Q:2:1",1,"SOURCE_ALIGNED"),
            # Must never enter the audio index.
            ("Q:2:1:W:2","Q:2:1",2,"UNMAPPED"),
        ])
        db.commit();db.close()

        source=tmp/"source"
        write_clip(source/"001"/"001_001_001.opus",1)
        write_clip(source/"001"/"001_001_002.opus",2)
        # Deliberate duplicate: a different canonical Word ID shares identical audio bytes.
        write_clip(source/"002"/"002_001_001.opus",1)
        evidence=tmp/"UPSTREAM.txt"
        evidence.write_text("Synthetic Apache-2.0 provenance fixture for offline test only.\n",encoding="utf-8")
        active=tmp/"active"
        revision="a"*40
        repo_id="selftest/quran-audio"
        lock=tmp/"source-lock.json"
        lock.write_text(json.dumps({
            "schema":1,
            "repo_id":repo_id,
            "repo_type":"dataset",
            "revision":revision,
            "declared_license_tag":"license:apache-2.0",
            "declared_license":"Apache-2.0",
            "style":"muallim",
            "extension":"opus",
            "canonical_policy":"SOURCE_ALIGNED_W_ONLY",
            "canonical_quran_sqlite_sha256":sha256(db_path),
            "expected_word_count":3
        },indent=2)+"\n",encoding="utf-8")

        run(sys.executable,ROOT/"tools/prepare_quran_audio.py",
            "--source",source,
            "--quran-db",db_path,
            "--output",active,
            "--license-evidence",evidence,
            "--source-name","Synthetic Quran Audio",
            "--source-version",revision,
            "--source-url",f"https://huggingface.co/datasets/{repo_id}",
            "--license","Apache-2.0",
            "--style","muallim",
            "--extension","opus",
            "--source-lock",lock)

        manifest=json.loads((active/"quran-audio"/"manifest.json").read_text(encoding="utf-8"))
        if manifest.get("schema_version")!=3:
            raise SystemExit("Self-test pack did not use schema v3")
        if manifest.get("word_count")!=3 or manifest.get("unique_clip_count")!=2:
            raise SystemExit("Content-addressed deduplication did not produce 3 references -> 2 unique clips")
        if manifest.get("deduplicated_reference_count")!=1 or manifest.get("pack_file_count")!=1:
            raise SystemExit("Unexpected self-test dedup/pack counts")

        run(sys.executable,ROOT/"tools/check_quran_audio.py",
            "--source",active,
            "--quran-db",db_path,
            "--source-lock",lock)

        pack=active/"quran-audio"/"packs"/"001.pack"
        data=bytearray(pack.read_bytes())
        data[0:4]=b"BAD!"
        pack.write_bytes(data)
        run(sys.executable,ROOT/"tools/check_quran_audio.py",
            "--source",active,
            "--quran-db",db_path,
            "--source-lock",lock,
            expect_ok=False)

    print("PASS: Quran audio builder/verifier synthetic self-test")


if __name__=="__main__":
    main()
