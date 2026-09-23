#!/usr/bin/env python3
"""Prepare a compact, website-independent Quran word-audio pack from local word clips.

Input is an already acquired SURAH/SURAH_AYAH_WORD.<extension> directory. The output contains
content-addressed audio clips packed into small seekable chunk files plus one SQLite byte-range
index, license/provenance evidence and a manifest. Identical audio bytes are stored only once.
Gradle/runtime never download source data and the APK never needs 77k separate assets.
"""
import argparse
import hashlib
import json
import os
import shutil
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_PACK_BYTES = 32 * 1024 * 1024
MAX_TOTAL_PACK_BYTES = 650 * 1024 * 1024
SOURCE_LOCK = ROOT / "source-vault/quran-audio/source-lock.json"


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
    parser.add_argument("--source-lock",type=Path,default=SOURCE_LOCK)
    args=parser.parse_args()

    source=args.source.resolve()
    quran_db=args.quran_db.resolve()
    output=args.output.resolve()
    evidence=args.license_evidence.resolve()
    extension=args.extension.lower().strip(".")
    source_lock=args.source_lock.resolve()

    if not source_lock.is_file():
        raise SystemExit("Reviewed Quran audio source lock is missing")
    lock=json.loads(source_lock.read_text(encoding="utf-8"))
    if lock.get("schema")!=1:
        raise SystemExit("Unsupported Quran audio source lock schema")
    if args.source_version.lower()!=str(lock.get("revision") or "").lower():
        raise SystemExit("Audio source version differs from reviewed source lock")
    if (args.license!=str(lock.get("declared_license") or "") or
        args.style!=str(lock.get("style") or "") or
        extension!=str(lock.get("extension") or "")):
        raise SystemExit("Audio source license/style/format differs from reviewed source lock")

    if not quran_db.is_file():
        raise SystemExit("quran.sqlite is missing; run python3 tools/build_content.py first")
    quran_hash=file_hash(quran_db)
    if quran_hash!=str(lock.get("canonical_quran_sqlite_sha256") or ""):
        raise SystemExit("Canonical quran.sqlite differs from reviewed audio source lock")
    if not evidence.is_file():
        raise SystemExit("License/provenance evidence file does not exist")
    if not extension.isalnum() or not 2<=len(extension)<=6:
        raise SystemExit("Invalid audio extension")

    rows=canonical_rows(quran_db)
    reviewed_count=int(lock.get("expected_word_count") or 0)
    if len(rows)!=reviewed_count:
        raise SystemExit(f"Canonical safe word count changed: {len(rows)} != reviewed {reviewed_count}")

    # Fail before writing staging output if any required coordinate is missing or obviously corrupt.
    missing=[]
    for _,ayah_id,position in rows:
        path=source_file(source,ayah_id,int(position),extension)
        if not path.is_file():
            missing.append(str(path))
            if len(missing)>=20:break
        else:
            with path.open("rb") as probe:
                header=probe.read(4)
            if path.stat().st_size<32 or header!=b"OggS":
                raise SystemExit(f"Invalid/corrupt Ogg Opus source clip: {path}")
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
    PRAGMA user_version=2;
    CREATE TABLE clip(
      word_id TEXT PRIMARY KEY,
      surah INTEGER NOT NULL,
      ayah INTEGER NOT NULL,
      position INTEGER NOT NULL,
      pack_id INTEGER NOT NULL,
      byte_offset INTEGER NOT NULL,
      byte_length INTEGER NOT NULL,
      clip_sha256 TEXT NOT NULL,
      UNIQUE(surah,ayah,position)
    );
    CREATE INDEX clip_coordinate ON clip(surah,ayah,position);
    CREATE INDEX clip_pack_range ON clip(pack_id,byte_offset);
    """)

    # digest -> (pack_id, offset, length). Repeated identical pronunciations reference the same
    # immutable range instead of storing duplicate bytes.
    dedup={}
    pack_meta={}
    current_out=None
    current_path=None
    current_pack_id=0
    current_unique=0
    references=0

    def finish_current_pack():
        nonlocal current_out,current_path,current_unique
        if current_out is None:return
        current_out.flush();os.fsync(current_out.fileno());current_out.close()
        pack_bytes=current_path.stat().st_size
        key=f"{current_pack_id:03d}"
        pack_meta[key]={
            "sha256":file_hash(current_path),
            "bytes":pack_bytes,
            "unique_clips":current_unique,
        }
        current_out=None;current_path=None;current_unique=0

    try:
        for word_id,ayah_id,position in rows:
            src=source_file(source,ayah_id,int(position),extension)
            data=src.read_bytes()
            if len(data)<32 or data[:4]!=b"OggS":
                raise ValueError(f"Source clip is not a valid Ogg container: {src}")
            digest=hashlib.sha256(data).hexdigest()
            location=dedup.get(digest)

            if location is None:
                if len(data)>MAX_PACK_BYTES:
                    raise ValueError(f"Single word clip exceeds chunk limit: {src}")
                if current_out is None or current_out.tell()+len(data)>MAX_PACK_BYTES:
                    finish_current_pack()
                    current_pack_id+=1
                    current_path=packs/f"{current_pack_id:03d}.pack"
                    current_out=current_path.open("wb")
                offset=current_out.tell()
                current_out.write(data)
                location=(current_pack_id,offset,len(data))
                dedup[digest]=location
                current_unique+=1
            elif location[2]!=len(data):
                raise ValueError(f"SHA-256 collision/length mismatch for {src}")

            pack_id,offset,length=location
            surah,ayah=coordinate(ayah_id)
            db.execute("INSERT INTO clip VALUES(?,?,?,?,?,?,?,?)",
                       (word_id,surah,ayah,int(position),pack_id,offset,length,digest))
            references+=1
            if references%5000==0:
                print(f"Indexed {references}/{len(rows)} words; unique clips={len(dedup)}",flush=True)

        finish_current_pack()
        if not pack_meta:
            raise ValueError("No Quran audio pack files were produced")

        total_pack_bytes=sum(meta["bytes"] for meta in pack_meta.values())
        if total_pack_bytes>MAX_TOTAL_PACK_BYTES:
            raise ValueError(f"Quran audio pack exceeds reviewed repository budget: {total_pack_bytes} bytes")

        db.commit()
        if db.execute("PRAGMA integrity_check").fetchone()[0]!="ok":
            raise ValueError("Audio index integrity check failed")
        if db.execute("SELECT count(*) FROM clip").fetchone()[0]!=len(rows):
            raise ValueError("Audio index word count mismatch")
        if db.execute("SELECT count(DISTINCT clip_sha256) FROM clip").fetchone()[0]!=len(dedup):
            raise ValueError("Audio dedup index mismatch")
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
            "schema_version":3,
            "pack_id":f"aaris-quran-word-audio-{args.style}-{args.source_version}",
            "source_name":args.source_name,
            "source_version":args.source_version,
            "source_url":args.source_url,
            "license":args.license,
            "license_files":[evidence_rel,"quran-audio/SOURCE.json"],
            "style":args.style,
            "source_file_extension":extension,
            "pack_layout":"CONTENT_ADDRESSED_CHUNKS_V1",
            "pack_root":"quran-audio/packs",
            "pack_chunk_limit_bytes":MAX_PACK_BYTES,
            "pack_file_count":len(pack_meta),
            "index_asset":"quran-audio/index.sqlite",
            "index_schema_version":2,
            "index_sha256":file_hash(index_path),
            "canonical_quran_sqlite_sha256":quran_hash,
            "source_lock_sha256":file_hash(source_lock),
            "word_count":len(rows),
            "unique_clip_count":len(dedup),
            "deduplicated_reference_count":len(rows)-len(dedup),
            "coverage_complete":True,
            "packs":pack_meta,
            "total_pack_bytes":total_pack_bytes,
            "runtime_network_required":False,
        }
        (stage/"quran-audio"/"manifest.json").write_text(
            json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8"
        )
    except Exception:
        try:finish_current_pack()
        except Exception:pass
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
        "word_references":len(rows),
        "unique_audio_clips":len(dedup),
        "deduplicated_references":len(rows)-len(dedup),
        "pack_files":len(pack_meta),
        "total_pack_bytes":total_pack_bytes,
        "style":args.style,
        "runtime_network_required":False,
    },ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()
