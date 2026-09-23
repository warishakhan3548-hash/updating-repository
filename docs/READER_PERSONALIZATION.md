# Reading, appearance and research integration

## Entry points

Today → Personalize Aaris opens Appearance, Translation/Reading, Reciter/Downloads,
and Study (pins and collections). The Quran reader keeps word taps and translations
under each ayah. Its action row uses Play, Bookmark, Study (book), and More, with
48 dp targets, accessibility labels and tooltips. Study is also available in More.

Study opens the original ayah and selected translation, translation comparison,
word meanings, a private note, pinning, collections, recall, source-aware copying,
translation feedback drafts and research PDF selection. Word taps inside Study
open word details; the reader's word-tap and audio behavior remain unchanged.
Existing bookmarks and Recall events remain separate from collections and pins.

## Shared appearance

One persisted model drives the reader, surfaces and preview. The original
Emerald Glass, Ocean Blue, Rose Glass and Midnight looks remain. Clean White,
Warm Paper and Easy Reading were removed from the one-tap preset strip and replaced
with premium token recipes: Lavender Aqua, Violet Glass, Burgundy Pearl, Lavender
Studio, Pearl Violet, Sapphire Neon, Rose Luxe, Mint Lilac, Amethyst Night and
Pearl Rose. These are not duplicated screens: every look feeds the same Appearance
model and the same production renderer, changing palette, gradient, card opacity,
corners, glass strength, border strength and glow in one deterministic preset.
The Start with a look strip renders miniature visual cards instead of flat text chips.
Background, cards, Arabic, translation and accent colors still have hue, saturation
and light/dark controls. Advanced finish controls expose separate Arabic/translation
opacity, glass strength, borders, subtle glow, card opacity, corners and a static
two-color background. Reduced effects remains available as a manual preference and
suppresses text effects and background gradients. No live backdrop blur or animated
shader is added.

The preview uses the actual installed 1:1 translation, attribution and RTL direction,
alongside canonical Arabic and the shared production renderers. Displayed text
colors are composited and contrast-corrected against the card's base/highlight;
opacity cannot force unreadable Quran text. This is not a device accessibility
certification. Undo/redo, reset and existing saved styles continue to use the same
model, with backward-compatible defaults for new fields.

The bundled Amiri Quran, Naskh and Naskh Bold choices are font variants, not new
Madani/QCF/IndoPak source representations. No Quran characters or word offsets change.

## Retrieval contract

Search engine version: ranked-7.

Both Quran and Hadith order text-match bands HIGH, then MEDIUM, then LOW. Quran
orders within a band by meaningful-token coverage, rare-token weighted coverage,
phrase, order/proximity, then score and transformation cost. The same comparator
selects the best evidence lane and query variant. Negation and injective token
matching remain in place. Bands are heuristic text-overlap labels, not calibrated
probabilities, authenticity grades, or guarantees of correct retrieval.

Hadith first preserves explicit reference lookup. Other matches use band, meaningful
coverage, then fixed 0.025 relevance buckets. Within the same bucket Bukhari and
then Muslim are preferred, followed by detailed text evidence. Fixed buckets keep
the comparator transitive; a pairwise floating-point epsilon would not. A stronger
band or higher meaningful coverage cannot be displaced by source preference. No
authenticity hierarchy for other books or missing individual grades is invented.

Result explanations expose matched meaningful words, exact normalized tokens,
spelling repairs and phrase/order evidence. Quran additionally identifies whether
the match came from Arabic, translation/word meanings or pronunciation shadows.
The 16,384-character limit, full paragraph scoring, separate fragments, pagination
and canonical record output remain.

“Remember this match” requires explicit confirmation. It saves an exact normalized
query-to-record shortcut in local user data, bound to the corpus pack hash. At most
100 shortcuts are retained for 180 days. They appear in a separately labelled card,
not as stronger textual evidence; there is no general learned token substitution,
semantic model or automatic click-based learning. Settings can clear them.

Hadith remains disk-backed with its current token/vocabulary/trigram indexes and
62,169 Arabic core-nine records. This patch does not add Roman/Hindi Hadith phonetic
indexes, multilingual source packs, grades, semantic search or narration families.
Similar records retain separate IDs and citations.

## Research and user data

Pins persist up to 10 ayahs. Up to 16 named collections hold 100 ayahs each, and an
ayah may belong to multiple collections. Local translation issue drafts retain
ayah, edition, source version, pack hash and user text; no source is edited or
message sent. Sharing a draft is an explicit user action.

These records and confirmed search shortcuts use the existing user-data setting
table and backup transaction, with validation and bounded JSON sizes. The restore
validator now accepts the existing translation_edition preference. This patch does
not claim encrypted backups or backup coverage for appearance/Android voice prefs.

Search result share opens the existing local PDF workflow. Selected or loaded
records are exported, and that scope is stated explicitly. The sheet offers Explain
Evidence, Compare Narrations, Compare Translations, Practice Described, Agreements
& Differences, and Custom Question. User instructions are separated from source
records in the PDF. Copy Prompt copies the chosen task only on a button press.

Two to ten selected records can be compared in the export sheet. Every Hadith keeps
its own collection, ID, Arabic, available translation and attributed grades.
Comparison does not infer a common narration family or a scholarly relationship.
Existing Quran ZIP/TXT/JSON evidence export and temporary PDF URI sharing remain.

## Voice and playback

Voice Search delegates to the chosen Android speech activity only after an explicit
notice and Start action. Recognized text enters the existing Quran or Hadith typed
search and remains editable. Offline recognition is requested but is not guaranteed
by Android providers. Missing providers/cancellation leave typed search available.
This is not recitation alignment, pronunciation correction or Tajweed grading.

Translation settings now offer installed device voices for the selected language,
with sample playback and a remembered choice. Network-required voices are excluded
using Android's Voice metadata. A missing saved voice produces a message instead
of silently choosing another. These are device voices, not scholar recordings.

Whole-ayah playback, repeat/continue, downloads and word audio are otherwise
unchanged. Background downloads, byte-range resume, sleep timers and expanded
audio storage controls remain separate work, as does any rights-cleared recitation
mirror. See source-vault/quran-audio/RECITATION.md.

## Validation status

See [UPGRADE_ACCEPTANCE_2026_09.md](UPGRADE_ACCEPTANCE_2026_09.md). This pass has
source review and added regression fixtures, but no JVM/Android execution:
the workspace connection failed with HTTP 503 and no execution tool was available.
The changes must remain a draft until the existing offline checks and Android
compile run. No APK/AAB or CI workflow is produced or requested.

Platform references consulted:
- https://developer.android.com/reference/android/speech/RecognizerIntent
- https://developer.android.com/reference/android/speech/tts/Voice
- https://developer.android.com/reference/android/speech/tts/TextToSpeech
