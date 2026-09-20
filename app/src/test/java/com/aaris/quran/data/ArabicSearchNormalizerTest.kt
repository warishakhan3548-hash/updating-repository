package com.aaris.quran.data

import org.junit.Assert.assertEquals
import org.junit.Test

class ArabicSearchNormalizerTest {
    @Test
    fun mirrorsPinnedDiacriticFreeVector() {
        val original = "ٱلْحَمْدُ ۞"
        assertEquals("ٱلحمد", ArabicSearchNormalizer.normalizeDiacriticFree(original))
        assertEquals(original, "ٱلْحَمْدُ ۞")
    }

    @Test
    fun collapsesWhitespaceAfterRemovingArabicMarks() {
        assertEquals(
            "الحمد لله",
            ArabicSearchNormalizer.normalizeDiacriticFree("الْحَمْدُ   لِلَّهِ"),
        )
    }

    @Test
    fun canonicalEquivalentUnicodeQueriesNormalizeEqually() {
        assertEquals(
            ArabicSearchNormalizer.normalizeUnicode("أ"),
            ArabicSearchNormalizer.normalizeUnicode("أ"),
        )
    }
}
