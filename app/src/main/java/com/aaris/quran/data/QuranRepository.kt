package com.aaris.quran.data

import com.aaris.quran.model.QuranAyah

enum class QuranSearchMatchKind {
    STRICT,
    APPROXIMATE_SPELLING,
}

data class QuranSearchHit(
    val ayah: QuranAyah,
    val matchKind: QuranSearchMatchKind,
)

interface QuranRepository {
    suspend fun ayahsForSurah(surah: Int): List<QuranAyah>
    suspend fun searchAyahs(query: String, limit: Int = 50): List<QuranSearchHit>
}
