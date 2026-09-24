# Published Hadith vowel marks — 24 September 2026

The earlier import chose Open-Hadith-Data's plain CSVs, intended for searching, and overlooked its
parallel vocalized (`mushakkala`) CSVs. The upstream README explicitly recommends displaying the
vocalized variant. No API key or automatic diacritization was necessary.

## Archived source

Repository: https://github.com/mhashim6/Open-Hadith-Data

Pinned revision: `1515f6cba21efed20d8916bf55acef1dffa0d2d5` (the same edition already installed).

All nine original vocalized CSVs are archived under
`source-vault/hadith/open-hadith-data/vocalized/` as deterministic gzip files (30,414,569 bytes total).
Decompression reconstructs the exact upstream bytes, including commentary columns. `SOURCE.json`
records upstream paths, Git blob SHA-1, SHA-256, sizes and compressed-file SHA-256. The original
README and license declaration are preserved; the latter corrects an extra period in the previously
copied license URL. Upstream declares ODbL 1.0 for the database and Database Contents License for
individual contents. This is Open-Hadith-Data/Islam Ware lineage, not Sunnah.com content.

| Collection | Records with source vowel marks |
| --- | ---: |
| Sahih al-Bukhari | 7,008 |
| Sahih Muslim | 5,362 |
| Sunan an-Nasa'i | 5,662 |
| Sunan Abi Dawud | 4,590 |
| Jami at-Tirmidhi | 3,891 |
| Sunan Ibn Majah | 4,332 |
| Muwatta Malik | 1,594 |
| Musnad Ahmad | 26,363 |
| Sunan ad-Darimi | 3,367 |
| **Total** | **62,169** |

## Import and identity

`prepare_open_hadith_data.py` requires the vocalized inventory, validates both variants' original
hashes, and matches every narration by collection, number and exact wording after removing vowel
marks and layout-only whitespace/RTL markers. It does not fold hamza, alef, ya, punctuation or word
order for identity checks. Missing files, records, marks, duplicate numbers and changed wording
stop preparation; there is no unvocalized fallback.

Only the narration column is imported. The optional third column is Arabic commentary, not a
translation, and cannot leak into the displayed narration. Display cleanup removes U+200F and
collapses whitespace only. Original letters, punctuation and all supplied vowel marks survive.
The unmodified CSV bytes remain available in the archive for inspection.

Existing `H:<collection>:open-hadith-data-1515f6cba21e:0:<number>` identities and reference aliases
stay stable. The pack content version changes to `1515f6cba21e-vocalized-v1`; the database checksum
changes, so an updated app installs the new pack without reusing the old plain database. Existing
search normalization still ignores vowel marks only in the index/query. Reading, copy and PDF
receive the vocalized text. The previously corrected Amiri Naskh layout renders it.

Gradle and direct release preparation already call this same offline preparer. Neither normal
rebuilds nor runtime Hadith reading/search contact the source website. All necessary source data
is committed in ordinary Git, with no Git LFS or external release-asset dependency.

## Verification and remaining limits

Offline verification commands (no APK or CI):

```sh
python3 tools/prepare_open_hadith_data.py
python3 tools/build_hadith.py --source build/generated/hadith-source
python3 tools/check_hadith.py
python3 tools/check.py
```

The verifier compares every installed Arabic text to its archived source column and checks every
old identity. Negative fixtures cover stripped marks, swapped words, wrong/duplicate numbers and
incomplete files. Database checks cover integrity, foreign keys, text hashes and source counts;
shared search checks cover vocalized/plain Arabic and multilingual number references.

All of the above passed against the rebuilt 62,169-record database. Both vocalized and plain
Arabic example queries ranked Bukhari 1 first. The existing 132 core checks, multilingual reference
regressions, all 6,236 recitation addresses and all 18,708 Quran translation/source-coordinate
comparisons also passed. No Android Java or layout code changed in this follow-up.

These are published source marks, with no generated diacritics. Mark coverage is not a claim that
every possible mark is supplied or that an independent scholar reviewed all 62,169 vocalizations.
Hindi, Urdu and English Hadith translations are still absent from this source. Edition numbering
is unchanged and can differ from Sunnah.com; Muslim 5556 still is not a record in this edition.
No APK, CI, emulator or physical-phone visual test is performed for this source update.
