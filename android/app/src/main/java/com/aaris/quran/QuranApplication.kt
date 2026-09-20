package com.aaris.quran

import android.app.Application
import com.aaris.quran.data.QuranContentRepository

class QuranApplication : Application() {
    val quranRepository: QuranContentRepository by lazy {
        QuranContentRepository(applicationContext)
    }
}
