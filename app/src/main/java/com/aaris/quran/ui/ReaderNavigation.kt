package com.aaris.quran.ui

object ReaderNavigation {
    const val FIRST_SURAH = 1
    const val LAST_SURAH = 114

    fun previous(current: Int): Int {
        require(current in FIRST_SURAH..LAST_SURAH)
        return (current - 1).coerceAtLeast(FIRST_SURAH)
    }

    fun next(current: Int): Int {
        require(current in FIRST_SURAH..LAST_SURAH)
        return (current + 1).coerceAtMost(LAST_SURAH)
    }
}
