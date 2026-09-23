# Reading, appearance and research integration

## Entry points

Today → Personalize Aaris opens Appearance, Translation/Reading and Reciter/Downloads.
The Quran reader retains word taps and adds complete translations underneath each
ayah. Play, bookmark and more use familiar icons, 48 dp targets and accessibility
labels/tooltips. More exposes copy, sharing, notes and device-voice translation.
Search headers expose PDF sharing when results exist; the export sheet states the
number of selected or loaded records. An explicit button copies the AI prompt.

## Shared appearance

One persisted visual model drives surfaces, Arabic type, colors and reader spacing.
Six starting palettes lead into independent background/card/Arabic/translation/accent
colors, hue and lightness, surface opacity, corners, text/card finish, actual font
variants, size and line spacing. Preview uses production text/surface classes.
There are undo/redo, named saved styles and reset. No live backdrop blur is required.
Contrast corrections affect displayed colors without changing scripture characters.
Amiri Quran, Amiri Naskh and Amiri Naskh Bold are bundled with OFL notices. All
codepoints used by the local Quran are covered in all three fonts. These choices
are typefaces, not a claim that an IndoPak/QCF/Madani text edition is installed.

## Retrieval

`TextMatch` provides injective token matching, overlap, order, exact phrase evidence,
transposition-aware edit distance and explicit negation preservation. Match bands
describe text overlap; they are not calibrated probabilities or authenticity grades.
Quran search combines canonical Arabic, archived word meanings/transliteration and
complete translations. Roman/Devanagari pronunciation shadows are retrieval-only.
Partial records stay below stronger overlaps. Exact fragments keep separate citations.
The input limit is 16,384 characters; a paragraph is scored without truncation.

Hadith's generated token/vocabulary/trigram tables live in the immutable SQLite pack.
Candidates are found globally before ranking; separate narration IDs are not deduplicated
by wording. Relevance comes first. Bukhari, then Muslim is a tie-break preference only;
the remaining books have no invented authenticity ladder. Individual grades retain
their recorded grader. The current core-nine pack contains Arabic only. No missing
Hindi/Urdu/English Hadith corpus or semantic embedding model is claimed.

Results load 50 at a time. More results can be loaded; export includes selected or
loaded results and explicitly states that scope. Each selected record is exported in
full with references, original text, available translation, grading and source identity.
It does not silently claim the entire database has been exported. PDFs use read-only
temporary URI grants. No AI provider receives anything until the user chooses a target
in Android's share sheet. Existing ZIP/JSON evidence tools remain available.

## Content and playback

The QuranEnc translation source is separate and hash-pinned. Build-time acquisition is
forbidden. See the translation vault README for rights/version requirements.
Mishary is the default optional whole-ayah reciter; playback and isolated word audio
remain distinct. Continue and 1/3/5 repeats advance on actual playback completion.
The media notification provides background controls. Downloads are scoped to the
selected reciter. See `source-vault/quran-audio/RECITATION.md` for precise limitations.

## Validation and remaining work

Run `python3 tools/build_content.py` and `python3 tools/check.py`; no APK or CI is needed.
Run the Hadith builder to regenerate its search index after this upgrade.
Behavioral checks cover full-versus-partial ranking, translation typos, transpositions,
long input, duplicate query words, absent queries and negation. Immutable text hashes,
6,236 coordinates and word spans are checked independently of appearance.

The implementation environment lacks an Android SDK. Android compilation, visual QA,
PDF rendering/sharing on receiving apps, large-font/landscape layout, recitation/network
failure and media-service lifecycle tests remain required on a device/SDK. No APK build
or phone-test claim is made. Urdu script conversion, additional Mushaf editions,
human translation-audio packs, semantic models and automatic correction learning are
not installed; they must not be advertised as completed features.
