# Optional whole-ayah recitation

This is independent of the pinned, isolated Muallim word-pronunciation containers.
Word taps still play complete isolated recordings. Whole-ayah playback never
supplies timestamps or sliced audio to the word-learning engine.

The catalog is limited to Mishary Rashid Alafasy (default), Mahmoud Khalil Al-Husary
and Mohamed Siddiq al-Minshawi, using the edition IDs and 128 kbps ayah format
documented at https://alquran.cloud/cdn (checked 2026-09-23).

Rights basis: https://alquran.cloud/terms-and-conditions, section IV, states that
recitations are offered for free non-commercial redistribution, streaming and
personal/educational downloads; reciters retain copyright. The app remains a
non-commercial preview and credits the reciter and Islamic Network. Recheck terms
before distribution or monetization. No blanket public-domain claim is made.

These sources are **REMOTE_OPTIONAL**, not owned mirrored snapshots. This change
does not archive the recitation bytes in GitHub, promise upstream permanence, or
turn a local integrity hash into a recording-rights or authenticity certificate.
Acquiring an owned mirror requires a separate pinned catalog of source hashes and
recording-rights review. Existing mirrored word audio remains independent.

The only network owner is `RecitationDownloads`. A user Play/Download action starts
acquisition; startup and all content builds stay offline. Each complete MP3 is
validated as decodable audio, installed locally and bound to a local SHA-256 digest.
Surah readiness is specific to reciter and Surah. Bulk downloads resume at complete
ayah boundaries. They do not claim byte-range resume. An incomplete track is
discarded and retried. Provider failure leaves Quran/Hadith/translation/search intact.

Foreground playback owns a media session, audio focus, notification controls and
completion-driven ayah transitions. Bulk downloads currently require keeping the
app open; completed files survive restart. Real-device playback, incoming-call,
lockscreen, headset and offline/download-failure tests are release gates.
