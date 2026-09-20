package com.aaris.quran.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SurahNavigationTest {
    @Test
    fun previous_stopsAtFirstSurah() {
        assertEquals(1, SurahNavigation.previous(1))
        assertEquals(57, SurahNavigation.previous(58))
    }

    @Test
    fun next_stopsAtLastSurah() {
        assertEquals(114, SurahNavigation.next(114))
        assertEquals(59, SurahNavigation.next(58))
    }

    @Test
    fun invalidSurah_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            SurahNavigation.next(0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SurahNavigation.previous(115)
        }
    }
}
