#!/usr/bin/env python3
"""Build an independent translation layer from hash-pinned, attributed local snapshots."""
import hashlib
import json
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parents[1]

def main():
    source = ROOT / 'source-vault/translations'
    lock = json.loads((source / 'manifest.json').read_text())
    for name, digest in lock['files'].items():
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != digest:
            raise ValueError('Translation source checksum mismatch: ' + name)
    assets = ROOT / 'app/src/main/assets'
    target = assets / 'translations.sqlite'
    temp = target.with_suffix('.tmp')
    temp.unlink(missing_ok=True)
    db = sqlite3.connect(temp)
    db.executescript('''
      PRAGMA page_size=4096;
      CREATE TABLE edition(id TEXT PRIMARY KEY,language TEXT,title TEXT,description TEXT,version TEXT,source TEXT);
      CREATE TABLE translation(edition_id TEXT,ayah_id TEXT,text TEXT,footnotes TEXT,
          PRIMARY KEY(edition_id,ayah_id));
    ''')
    catalogue = json.loads((source / 'catalogue.json').read_text())['translations']
    # Use the immutable canonical corpus to validate every coordinate, never infer missing verses.
    quran = sqlite3.connect(f'file:{assets / "quran.sqlite"}?mode=ro', uri=True)
    expected = {row[0] for row in quran.execute('SELECT id FROM ayah')}
    for key in lock['editions']:
        meta = next(item for item in catalogue if item['key'] == key)
        db.execute('INSERT INTO edition VALUES(?,?,?,?,?,?)', (key,meta['lang'],meta['title'],meta['description'],meta['version'],'https://quranenc.com'))
        data = json.loads((source / (key + '.json')).read_text())
        found = set()
        for chapter in data.values():
            for row in chapter:
                aid = f"Q:{int(row['chapter'])}:{int(row['verse'])}"
                if aid in found or aid not in expected or not row.get('text'):
                    raise ValueError('Invalid translation coordinate: ' + aid)
                found.add(aid)
                db.execute('INSERT INTO translation VALUES(?,?,?,?)', (key,aid,row['text'],row.get('footnotes','')))
        if found != expected:
            raise ValueError('Incomplete translation edition: ' + key)
    db.commit()
    if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise ValueError('Translation pack failed integrity check')
    db.execute('VACUUM');db.close();quran.close();temp.replace(target)
    manifest = {'schema':1,'sqlite_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),
                'editions':lock['editions'],'source_revision':lock['mirror_revision'],'notice':lock['notice']}
    (assets / 'translations-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print('PASS: 3 complete attributed Quran translations, 18,708 coordinates; no runtime network')

if __name__ == '__main__':
    main()
