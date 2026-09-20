package com.aaris.quran.data

import java.text.Normalizer

/**
 * Android mirror of the pinned quran-core search normalization contract.
 *
 * This transforms queries only. Source/display Quran text remains untouched.
 */
internal object ArabicSearchNormalizer {
    const val VERSION = "arabic-search-v1"

    private val removeRanges = arrayOf(
        0x0610..0x061A,
        0x064B..0x065F,
        0x06D6..0x06DC,
        0x06DF..0x06E6,
        0x06E7..0x06E8,
        0x06EA..0x06ED,
        0x08D3..0x08FF,
    )

    private val removeSingles = setOf(
        0x0640, // TATWEEL
        0x0670, // ARABIC LETTER SUPERSCRIPT ALEF
        0x06DD, // END OF AYAH
        0x06DE, // START OF RUB EL HIZB
        0x06E9, // PLACE OF SAJDAH
    )

    fun normalizeUnicode(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFC)

    fun normalizeDiacriticFree(text: String): String {
        val canonical = normalizeUnicode(text)
        val stripped = buildString(canonical.length) {
            canonical.forEach { char ->
                val codePoint = char.code
                if (codePoint !in removeSingles && removeRanges.none { codePoint in it }) {
                    append(char)
                }
            }
        }

        return buildString(stripped.length) {
            var pendingSpace = false
            stripped.forEach { char ->
                if (char.isWhitespace() || Character.isSpaceChar(char)) {
                    if (isNotEmpty()) pendingSpace = true
                } else {
                    if (pendingSpace) {
                        append(' ')
                        pendingSpace = false
                    }
                    append(char)
                }
            }
        }
    }
}
