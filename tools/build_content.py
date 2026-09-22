#!/usr/bin/env python3
"""Reproducible, offline-only content builder. Source Arabic is never rewritten."""
import ast
import hashlib
import json
import re
import sqlite3
import unicodedata
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VAULT = ROOT / 'source-vault'
ASSETS = ROOT / 'app/src/main/assets'
RAW_SHA = '4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def shadow(text):
    # Comparison lane only. No original source field is normalized.
    text = unicodedata.normalize('NFC', text)
    return ''.join(c for c in text if not unicodedata.category(c).startswith('M')
                   and c not in '\u0640\u06de\u06e9\u06e5\u06e6').replace('ٱ', 'ا').strip()


def source_words(text):
    # Waqf/sajdah markers are retained in the display string, excluded from word IDs.
    return [(m.start(), m.end(), m.group()) for m in re.finditer(r'\S+', text)
            if any('\u0621' <= c <= '\u064a' or c == 'ٱ' for c in m.group())]


def build():
    # A missing or edited source must not silently become a new release.
    lock = json.loads((ROOT / 'tools/source-lock.json').read_text())
    for relative, expected in lock['source_sha256'].items():
        source = VAULT / relative
        if not source.is_file() or digest(source) != expected:
            raise ValueError(f'Pinned source missing or changed: {relative}')
    raw = VAULT / 'tanzil/quran-uthmani.txt'
    assert digest(raw) == RAW_SHA, 'Quran source changed: release blocked'
    rows = []
    for line in raw.read_text().splitlines():
        if re.match(r'^\d+\|', line):
            s, a, text = line.split('|', 2)
            rows.append((int(s), int(a), text))
    assert len(rows) == 6236 and len({(s, a) for s, a, _ in rows}) == 6236
    meta = (VAULT / 'tanzil/quran-data.js').read_text()
    suras = []
    for line in meta.split('QuranData.Sura = [', 1)[1].split('];', 1)[0].splitlines():
        line = line.strip().rstrip(',')
        if not re.match(r'^\[\d', line):
            continue
        v = ast.literal_eval(line)
        if len(v) != 8:
            continue
        name = v[4]
        if 'Ø' in name or 'Ù' in name:
            # Upstream metadata has mixed Windows-1252/Latin-1 mojibake.
            # Decode only the metadata label; preserve the archived bytes.
            name = b''.join(bytes([ord(c)]) if ord(c) < 256 else c.encode('cp1252') for c in name).decode('utf8')
        suras.append((len(suras) + 1, name, v[5], v[6], v[1], v[7]))
    assert len(suras) == 114 and sum(s[4] for s in suras) == 6236
    for s in suras:
        assert [a for sn, a, _ in rows if sn == s[0]] == list(range(1, s[4] + 1))

    source_dir = VAULT / 'data-quran'
    def data(path):
        return json.loads((source_dir / path).read_text())
    mapping = data('word/word.json')
    arabic = data('word-text/uthmani-qurancom.json')
    glosses = {lang: data(f'word-translation/{lang}-qurancom.json') for lang in ('en', 'hi', 'ur')}
    translit = data('word-transliteration/en-qurancom.json')
    by_ayah = defaultdict(list)
    for key, m in mapping.items():
        by_ayah[(m['surah'], m['ayah'])].append((m['position'], key))
    for group in by_ayah.values():
        group.sort()
    ASSETS.mkdir(parents=True, exist_ok=True)
    output = ASSETS / 'quran.sqlite'
    temporary = ASSETS / 'quran.sqlite.tmp'
    temporary.unlink(missing_ok=True)
    db = sqlite3.connect(temporary)
    db.executescript('''
    PRAGMA page_size=4096;
    PRAGMA user_version=1;
    CREATE TABLE surah(id INTEGER PRIMARY KEY, arabic TEXT NOT NULL, name TEXT NOT NULL,
                      meaning TEXT NOT NULL, count INTEGER NOT NULL, revelation TEXT NOT NULL);
    CREATE TABLE ayah(id TEXT PRIMARY KEY, surah INTEGER NOT NULL, number INTEGER NOT NULL,
                     arabic TEXT NOT NULL, sha256 TEXT NOT NULL, ordinal INTEGER NOT NULL UNIQUE,
                     UNIQUE(surah,number));
    CREATE TABLE word(id TEXT PRIMARY KEY, ayah_id TEXT NOT NULL, position INTEGER NOT NULL,
                      start_cp INTEGER NOT NULL, end_cp INTEGER NOT NULL, arabic TEXT NOT NULL,
                      surface_key TEXT NOT NULL, gloss_en TEXT, gloss_hi TEXT, gloss_ur TEXT,
                      transliteration TEXT, source_ref TEXT, mapping_state TEXT NOT NULL,
                      FOREIGN KEY(ayah_id) REFERENCES ayah(id));
    CREATE INDEX words_by_ayah ON word(ayah_id,position);
    CREATE INDEX words_by_surface ON word(surface_key);
    CREATE TABLE provenance(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE hadith_record(id TEXT PRIMARY KEY, collection TEXT NOT NULL, edition TEXT NOT NULL,
                     numbering_scheme TEXT NOT NULL, number TEXT NOT NULL, arabic TEXT NOT NULL,
                     matn TEXT, isnad TEXT, source_url TEXT NOT NULL, pack_id TEXT NOT NULL);
    CREATE TABLE grade_assertion(id TEXT PRIMARY KEY, record_id TEXT NOT NULL, grade TEXT NOT NULL,
                     grader TEXT NOT NULL, source_version TEXT NOT NULL);
    ''')
    db.executemany('INSERT INTO surah VALUES(?,?,?,?,?,?)', suras)
    unmatched, mapped, word_count = [], 0, 0
    bismillah = rows[0][2]
    for ordinal, (s, a, text) in enumerate(rows):
        aid = f'Q:{s}:{a}'
        db.execute('INSERT INTO ayah VALUES(?,?,?,?,?,?)',
                   (aid, s, a, text, hashlib.sha256(text.encode()).hexdigest(), ordinal))
        tokens = source_words(text)
        # Tanzil txt-2 embeds the opening basmala in first ayahs (except 1 and 9).
        # Preserve every source byte. Mapping skips those four prefatory words explicitly.
        prefatory = a == 1 and s not in (1, 9) and text.startswith(bismillah + ' ')
        prefix_count = 4 if prefatory else 0
        candidates = by_ayah.get((s, a), [])
        body = tokens[prefix_count:]
        valid = len(body) == len(candidates) and all(
            shadow(tok[2]) == shadow(arabic.get(key, ''))
            for tok, (_, key) in zip(body, candidates))
        if not valid:
            unmatched.append({'ayah': aid, 'source_words': len(body), 'gloss_words': len(candidates),
                              'reason': 'word count or Arabic parity mismatch; no body gloss attached'})
        for i, (start, end, token) in enumerate(tokens):
            # Prefatory IDs are separate from canonical ayah word coordinates.
            pre = i < prefix_count
            key = str(i + 1) if pre else (candidates[i-prefix_count][1] if valid else None)
            position = i + 1 - prefix_count
            wid = f'{aid}:B:{i+1}' if pre else f'{aid}:W:{position}'
            g = [glosses[lang].get(key) if key else None for lang in ('en', 'hi', 'ur')]
            if key:
                mapped += 1
            db.execute('INSERT INTO word VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
                       (wid, aid, position, start, end, token, shadow(token), *g,
                        translit.get(key) if key else None,
                        f'data-quran:023b2f59:{key}' if key else None,
                        'SOURCE_ALIGNED' if key else 'UNMAPPED'))
            word_count += 1
    (ASSETS/'licenses').mkdir(exist_ok=True)
    copyright_start = raw.read_text().index('#  Tanzil Quran Text')
    notice = '\n'.join(line.removeprefix('#').removeprefix(' ') for line in raw.read_text()[copyright_start:].splitlines()
                       if not line.startswith('#===')) + '\n'
    (ASSETS/'licenses/TANZIL.txt').write_text(notice)
    (ASSETS/'licenses/DATA-QURAN.txt').write_text((source_dir/'LICENSE').read_text())
    attribution = ('Quran Arabic: Tanzil Project, Uthmani 1.1. https://tanzil.net/\n'
                   'Word glosses/transliteration: Data Quran, collected by Hablullah team from Quran.com; '
                   'archived at https://github.com/mamun-al-abdullah/quran commit 023b2f59edcf5cea0f4218a50039c6e6fc7154bc.\n'
                   'https://creativecommons.org/licenses/by-nc-nd/4.0/ — non-commercial, unchanged source values.\n'
                   'These are imported source glosses, not a newly reviewed Aaris translation or tafsir. '
                   'Surface alignment is an integrity check, not scholarly validation.\n'
                   'Amiri Quran: Amiri Project Authors, SIL OFL 1.1. https://github.com/aliftype/amiri\n')
    (ASSETS/'licenses/ATTRIBUTION.txt').write_text(attribution)
    for k, v in {'pack_id':'quran-core-1', 'raw_sha256':RAW_SHA,'quran_source':'https://tanzil.net/',
                 'gloss_status':'SOURCE_IMPORTED_NOT_INDEPENDENTLY_REVIEWED',
                 'distribution':'NON_COMMERCIAL_PREVIEW','attribution':attribution}.items():
        db.execute('INSERT INTO provenance VALUES(?,?)', (k, v))
    db.commit()
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
    db.execute('VACUUM')
    db.close()
    temporary.replace(output)
    manifest = {'schema_version':1,'pack_id':'quran-core-1','content_version':'1.0.0',
                'quran_source_sha256':RAW_SHA,'sqlite_sha256':digest(output),
                'surahs':114,'ayahs':6236,'words':word_count,'source_aligned_words':mapped,
                'unmapped_ayah_count':len(unmatched), 'distribution':'NON_COMMERCIAL_PREVIEW',
                'review_status':'SOURCE_IMPORTED; linguistic review pending',
                'gloss_source_commit':'023b2f59edcf5cea0f4218a50039c6e6fc7154bc',
                'builder_version':'1','signature':None,'update_policy':'APK_BUNDLED_ONLY',
                'sources':{str(p.relative_to(VAULT)):digest(p) for p in sorted(VAULT.rglob('*')) if p.is_file()}}
    (ASSETS/'content-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    report = {'summary':{k:manifest[k] for k in ('surahs','ayahs','words','source_aligned_words','unmapped_ayah_count')},
              'unmapped':unmatched, 'policy':'Fail closed per ayah; never shift word mappings after a mismatch.'}
    (ROOT/'docs/content-validation.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report['summary']))
    print('Pack SHA-256:', manifest['sqlite_sha256'])


if __name__ == '__main__':
    build()
