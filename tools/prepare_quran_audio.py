#!/usr/bin/env python3
"""Prepare a compact, website-independent Quran word-audio pack from local word clips.

Input is an already acquired SURAH/SURAH_AYAH_WORD.<extension> directory. The output contains
only 114 Surah pack files plus one SQLite byte-range index, license/provenance evidence and a
manifest. Gradle/runtime never download source data and the APK never needs 77k separate assets.
"""
import argparse
import hashlib
import json
import shutil
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def file_hash(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()


def canonical_rows(db_path: Path):
    db=sqlite3.connect(f"file:{db_path}?mode=ro",uri=True)
    try:
        return list(db.execute(
            "SELECT id,ayah_id,position FROM word "
            "WHERE position>0 AND id LIKE '%:W:%' AND mapping_state='SOURCE_ALIGNED' ORDER BY "
            "CAST(substr(ayah_id,3,instr(substr(ayah_id,3),':')-1) AS INTEGER),"
            "CAST(substr(ayah_id,instr(substr(ayah_id,3),':')+3) AS INTEGER),position"
        ))
    finally:
        db.close()


def coordinate(ayah_id: str):
    parts=ayah_id.split(":")
    if len(parts)!=3 or parts[0]!="Q":
        raise ValueError(f"Invalid ayah id {ayah_id}")
    return int(parts[1]),int(parts[2])


def source_file(source: Path, ayah_id: str, position: int, extension: str) -> Path:
    surah,ayah=coordinate(ayah_id)
    return source/f"{surah:03d}"/f"{surah:03d}_{ayah:03d}_{position:03d}.{extension}"


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--source",required=True,type=Path)
    parser.add_argument("--quran-db",type=Path,default=ROOT/"app/src/main/assets/quran.sqlite")
    parser.add_argument("--output",type=Path,default=ROOT/"source-vault/quran-audio/active")
    parser.add_argument("--license-evidence",required=True,type=Path)
    parser.add_argument("--source-name",required=True)
    parser.add_argument("--source-version",required=True)
    parser.add_argument("--source-url",required=True)
    parser.add_argument("--license",required=True)
    parser.add_argument("--style",default="muallim")
    parser.add_argument("--extension",default="opus")
    args=parser.parse_args()

    source=args.source.resolve()
    quran_db=args.quran_db.resolve()
    output=args.output.resolve()
    evidence=args.license_evidence.resolve()
    extension=args.extension.lower().strip(".")

    if not quran_db.is_file():
        raise SystemExit("quran.sqlite is missing; run python3 tools/build_content.py first")
    if not evidence.is_file():
        raise SystemExit("License/provenance evidence file does not exist")
    if not extension.isalnum() or not 2<=len(extension)<=6:
        raise SystemExit("Invalid audio extension")

    rows=canonical_rows(quran_db)
    missing=[]
    for _,ayah_id,position in rows:
        path=source_file(source,ayah_id,int(position),extension)
        if not path.is_file():
            missing.append(str(path))
            if len(missing)>=20:break
    if missing:
        raise SystemExit("Source audio does not cover canonical word coordinates: "+", ".join(missing))

    stage=output.with_name(output.name+".tmp")
    old=output.with_name(output.name+".old")
    shutil.rmtree(stage,ignore_errors=True)
    shutil.rmtree(old,ignore_errors=True)
    packs=stage/"quran-audio"/"packs"
    licenses=stage/"quran-audio"/"LICENSES"
    packs.mkdir(parents=True)
    licenses.mkdir(parents=True)

    index_path=stage/"quran-audio"/"index.sqlite"
    db=sqlite3.connect(index_path)
    db.executescript("""
    PRAGMA page_size=4096;
    PRAGMA user_version=1;
    CREATE TABLE clip(
      word_id TEXT PRIMARY KEY,
      surah INTEGER NOT NULL,
      ayah INTEGER NOT NULL,
      position INTEGER NOT NULL,
      byte_offset INTEGER NOT NULL,
      byte_length INTEGER NOT NULL
    );
    CREATE INDEX clip_coordinate ON clip(surah,ayah,position);
    """)

    by_surah={}
    for row in rows:
        _,ayah_id,_=row
        surah,_=coordinate(ayah_id)
        by_surah.setdefault(surah,[]).append(row)

    pack_meta={}
    copied=0
    try:
        for surah in range(1,115):
            pack_path=packs/f"{surah:03d}.pack"
            count=0
            with pack_path.open("wb") as out:
                for word_id,ayah_id,position in by_surah.get(surah,[]):
                    src=source_file(source,ayah_id,int(position),extension)
                    length=src.stat().st_size
                    if length<32:
                        raise ValueError(f"Suspiciously small source audio: {src}")
                    offset=out.tell()
                    with src.open("rb") as inp:
                        shutil.copyfileobj(inp,out,1024*1024)
                    _,ayah=coordinate(ayah_id)
                    db.execute("INSERT INTO clip VALUES(?,?,?,?,?,?)",
                               (word_id,surah,ayah,int(position),offset,length))
                    count+=1;copied+=1
                    if copied%5000==0:
                        print(f"Packed {copied}/{len(rows)} words",flush=True)
            pack_meta[f"{surah:03d}"]={
                "sha256":file_hash(pack_path),
                "bytes":pack_path.stat().st_size,
                "words":count,
            }

        db.commit()
        if db.execute("PRAGMA integrity_check").fetchone()[0]!="ok":
            raise ValueError("Audio index integrity check failed")
        if db.execute("SELECT count(*) FROM clip").fetchone()[0]!=len(rows):
            raise ValueError("Audio index word count mismatch")
        db.execute("VACUUM")
        db.close()

        evidence_rel="quran-audio/LICENSES/UPSTREAM.txt"
        shutil.copy2(evidence,stage/evidence_rel)
        source_meta={
            "source_name":args.source_name,
            "source_version":args.source_version,
            "source_url":args.source_url,
            "declared_license":args.license,
            "style":args.style,
            "source_format":extension,
            "note":"Audio was acquired before build. Android build/runtime perform no network fetch.",
        }
        (stage/"quran-audio"/"SOURCE.json").write_text(
            json.dumps(source_meta,ensure_ascii=False,indent=2)+"\n",encoding="utf-8"
        )
        manifest={
            "schema_version":2,
            "pack_id":f"aaris-quran-word-audio-{args.style}-{args.source_version}",
            "source_name":args.source_name,
            "source_version":args.source_version,
            "source_url":args.source_url,
            "license":args.license,
            "license_files":[evidence_rel,"quran-audio/SOURCE.json"],
            "style":args.style,
            "source_file_extension":extension,
            "pack_root":"quran-audio/packs",
            "index_asset":"quran-audio/index.sqlite",
            "index_sha256":file_hash(index_path),
            "word_count":len(rows),
            "coverage_complete":True,
            "surah_packs":pack_meta,
            "runtime_network_required":False,
        }
        (stage/"quran-audio"/"manifest.json").write_text(
            json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8"
        )
    except Exception:
        try:db.close()
        except Exception:pass
        shutil.rmtree(stage,ignore_errors=True)
        raise

    if output.exists():output.rename(old)
    stage.rename(output)
    shutil.rmtree(old,ignore_errors=True)
    print(json.dumps({
        "status":"PREPARED",
        "output":str(output),
        "word_files_packed":len(rows),
        "surah_pack_files":114,
        "style":args.style,
        "runtime_network_required":False,
    },ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()
