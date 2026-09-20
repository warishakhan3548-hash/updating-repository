package com.aaris.quran.data

import com.aaris.quran.model.QuranAyah

interface QuranRepository {
    suspend fun ayahsForSurah(surah: Int): List<QuranAyah>
    suspend fun searchAyahs(query: String, limit: Int = 50): List<QuranAyah>
}
