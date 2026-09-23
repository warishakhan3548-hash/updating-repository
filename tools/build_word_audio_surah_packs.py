#!/usr/bin/env python3
"""Build immutable per-Surah isolated-word audio containers without transcoding.

Input is the pinned Quranic-Word-By-Word-Audio-Data Muallim directory. Every source .opus file
is copied byte-for-byte into exactly one .aqp container. No full-Surah waveform, timestamp slicing,
re-encoding, padding or cross-word audio is introduced.

AQP v1 layout:
  magic      b"AARISQW1\n"
  uint32be   index byte length
  index      UTF-8 TSV lines: ayah<TAB>position<TAB>payload_offset<TAB>length
  payload    exact source Ogg/Opus clips concatenated in Quran coordinate order

payload_offset is relative to the first payload byte. Android can therefore address one complete
Ogg/Opus file with FileDescriptor + offset + length and play it from its own beginning to its own
natural completion.
"""
import argparse
import hashlib
import json
import sqlite3
import struct
from collections import defaultdict
from pathlib import Path

MAGIC=b"AARISQW1\n"
EXPECTED_WORDS=77326
MAX_CLIP_BYTES=2*1024*1024
MAX_INDEX_BYTES=4*1024*1024


def sha256(path):
    h=hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()


def alignment_identity(db):
    h=hashlib.sha256();count=0
    for wid,aid,pos,arabic in db.execute(
        "SELECT id,ayah_id,position,arabic FROM word "
        "WHERE position>0 AND id LIKE '%:W:%' AND mapping_state='SOURCE_ALIGNED' ORDER BY id"
    ):
        h.update(f"{wid}\\t{aid}\\t{pos}\\t{arabic}\\n".encode("utf-8"));count+=1
    return h.hexdigest(),count


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--source",type=Path,required=True,
                   help="Pinned Muallim directory containing 001/, 002/, ...")
    p.add_argument("--quran-db",type=Path,required=True)
    p.add_argument("--source-lock",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True)
    p.add_argument("--release-base-url",required=True)
    args=p.parse_args()

    lock=json.loads(args.source_lock.read_text(encoding="utf-8"))
    if lock.get("schema")!=2 or lock.get("delivery")!="ISOLATED_WORD_SURAH_CONTAINER_V1":
        raise SystemExit("Unsupported isolated-word source lock")
    if lock.get("style")!="muallim" or lock.get("extension")!="opus":
        raise SystemExit("Aaris v1 pronunciation pack must use pinned Muallim Opus clips")
    revision=str(lock.get("revision") or "")
    if len(revision)!=40:
        raise SystemExit("Invalid immutable audio revision")

    db=sqlite3.connect(f"file:{args.quran_db.resolve()}?mode=ro",uri=True)
    try:
        alignment,count=alignment_identity(db)
        if count!=EXPECTED_WORDS:
            raise SystemExit(f"Canonical isolated-word count changed: {count}")
        if alignment!=lock.get("canonical_quran_alignment_sha256"):
            raise SystemExit("Canonical Quran word identity differs from audio source lock")
        raw_rows=list(db.execute(
            "SELECT ayah_id,position FROM word WHERE position>0 AND id LIKE '%:W:%' "
            "AND mapping_state='SOURCE_ALIGNED'"
        ))
        rows=[]
        for ayah_id,pos in raw_rows:
            parts=str(ayah_id).split(":")
            if len(parts)!=3 or parts[0]!="Q":
                raise SystemExit(f"Invalid canonical ayah identity: {ayah_id}")
            rows.append((int(parts[1]),int(parts[2]),int(pos)))
        rows.sort()
    finally:
        db.close()

    grouped=defaultdict(list)
    for surah,ayah,pos in rows:
        grouped[int(surah)].append((int(ayah),int(pos)))
    if set(grouped)!=set(range(1,115)):
        raise SystemExit("Canonical word map does not cover all 114 Surahs")

    args.output.mkdir(parents=True,exist_ok=True)
    packs={}
    total_bytes=0
    total_words=0
    for surah in range(1,115):
        sn=f"{surah:03d}"
        entries=[]
        payload_offset=0
        clip_paths=[]
        for ayah,pos in grouped[surah]:
            name=f"{sn}_{ayah:03d}_{pos:03d}.opus"
            clip=args.source/sn/name
            if not clip.is_file():
                raise SystemExit(f"Missing isolated word clip: {clip}")
            size=clip.stat().st_size
            if size<32 or size>MAX_CLIP_BYTES:
                raise SystemExit(f"Invalid isolated word clip size: {clip} -> {size}")
            with clip.open("rb") as f:
                if f.read(4)!=b"OggS":
                    raise SystemExit(f"Not an Ogg/Opus word clip: {clip}")
            entries.append((ayah,pos,payload_offset,size))
            clip_paths.append(clip)
            payload_offset+=size

        index=("".join(f"{ayah}\t{pos}\t{off}\t{length}\n" for ayah,pos,off,length in entries)).encode("utf-8")
        if not index or len(index)>MAX_INDEX_BYTES:
            raise SystemExit(f"Invalid index size for Surah {surah}: {len(index)}")

        target=args.output/f"{sn}.aqp"
        temp=target.with_suffix(".aqp.tmp")
        h=hashlib.sha256()
        with temp.open("wb") as out:
            prefix=MAGIC+struct.pack(">I",len(index))+index
            out.write(prefix);h.update(prefix)
            for clip in clip_paths:
                with clip.open("rb") as src:
                    for chunk in iter(lambda:src.read(1024*1024),b""):
                        out.write(chunk);h.update(chunk)
        temp.replace(target)
        file_bytes=target.stat().st_size
        packs[sn]={
            "words":len(entries),
            "bytes":file_bytes,
            "sha256":h.hexdigest(),
            "url":args.release_base_url.rstrip("/")+"/"+target.name,
        }
        total_bytes+=file_bytes
        total_words+=len(entries)
        print(f"{sn}: {len(entries)} words -> {file_bytes} bytes",flush=True)

    if total_words!=EXPECTED_WORDS:
        raise SystemExit(f"Packed word total mismatch: {total_words}")

    catalog={
        "schema":1,
        "delivery":"ISOLATED_WORD_SURAH_CONTAINER_V1",
        "container_magic":"AARISQW1",
        "repo_id":lock["repo_id"],
        "source_revision":revision,
        "style":"muallim",
        "audio_format":"Ogg Opus isolated word clips",
        "canonical_quran_alignment_sha256":alignment,
        "canonical_quran_audio_words":total_words,
        "surahs":114,
        "total_bytes":total_bytes,
        "release_base_url":args.release_base_url.rstrip("/"),
        "packs":packs,
    }
    catalog_path=args.output/"catalog.json"
    catalog_path.write_text(json.dumps(catalog,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({
        "surahs":114,"words":total_words,"bytes":total_bytes,
        "catalog_sha256":sha256(catalog_path)
    },indent=2))


if __name__=="__main__":
    main()
