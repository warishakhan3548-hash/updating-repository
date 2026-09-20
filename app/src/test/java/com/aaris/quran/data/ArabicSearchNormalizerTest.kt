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
    fun constrainedVariantNormalizesArabicOrthographyWithoutChangingInput() {
        val original = "فَإِنَّ مَعَ ٱلْعُسْرِ يُسْرًا"
        assertEquals(
            "فان مع العسر يسرا",
            ArabicSearchNormalizer.normalizeConstrainedVariant(original),
        )
        assertEquals("فَإِنَّ مَعَ ٱلْعُسْرِ يُسْرًا", original)
    }

    @Test
    fun constrainedVariantNormalizesSouthAsianKeyboardLetters() {
        assertEquals(
            "الحي القيوم قل هو ملك",
            ArabicSearchNormalizer.normalizeConstrainedVariant("الحی القیوم قل ہو ملک"),
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
