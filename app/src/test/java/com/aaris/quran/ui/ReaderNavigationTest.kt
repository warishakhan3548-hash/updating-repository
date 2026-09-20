package com.aaris.quran.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderNavigationTest {
    @Test
    fun acceptsCanonicalSurahRange() {
        assertTrue(isCanonicalSurahNumber(1))
        assertTrue(isCanonicalSurahNumber(114))
    }

    @Test
    fun rejectsNumbersOutsideCanonicalSurahRange() {
        assertFalse(isCanonicalSurahNumber(0))
        assertFalse(isCanonicalSurahNumber(115))
        assertFalse(isCanonicalSurahNumber(-1))
    }
}
