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
    @Test
    fun foldsOnlyVersionedCompatibilityCharacters() {
        assertEquals(
            "فان مع العسر يسرا",
            ArabicSearchNormalizer.normalizeCompatibility("فإن مع ٱلعسر يسرا"),
        )
        assertEquals(
            "الحي القيوم",
            ArabicSearchNormalizer.normalizeCompatibility("الحی القیوم"),
        )
        assertEquals(
            "قل هو",
            ArabicSearchNormalizer.normalizeCompatibility("قل ہو"),
        )
        assertEquals(
            "ک ي",
            ArabicSearchNormalizer.normalizeCompatibility("ک ى"),
        )
    }

}
