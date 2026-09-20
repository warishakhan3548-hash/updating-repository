package com.aaris.quran.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class QuranRepositoryContractTest {
    @Test
    fun displayQueryUsesOriginalTextAndNeverSearchLanes() {
        val sql = QuranRepository.READ_SURAH_SQL.lowercase()
        assertTrue(sql.contains("original_text"))
        assertFalse(sql.contains("search_unicode"))
        assertFalse(sql.contains("search_diacritic_free"))
    }

    @Test
    fun displayQueryIsCoordinateOrdered() {
        val sql = QuranRepository.READ_SURAH_SQL.lowercase()
        assertTrue(sql.contains("where surah = ?"))
        assertTrue(sql.contains("order by ayah"))
    }
}
