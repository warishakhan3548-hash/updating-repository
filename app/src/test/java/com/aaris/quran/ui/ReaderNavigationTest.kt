package com.aaris.quran.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ReaderNavigationTest {
    @Test
    fun previous_stopsAtFirstSurah() {
        assertEquals(1, ReaderNavigation.previous(1))
        assertEquals(57, ReaderNavigation.previous(58))
    }

    @Test
    fun next_stopsAtLastSurah() {
        assertEquals(114, ReaderNavigation.next(114))
        assertEquals(59, ReaderNavigation.next(58))
    }

    @Test
    fun invalidSurah_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            ReaderNavigation.next(0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ReaderNavigation.previous(115)
        }
    }
}
