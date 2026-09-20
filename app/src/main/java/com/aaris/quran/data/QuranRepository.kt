package com.aaris.quran.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase

data class QuranAyah(
    val surah: Int,
    val ayah: Int,
    val originalText: String,
)

class QuranRepository(context: Context) {
    private val appContext = context.applicationContext
    private val installer = QuranPackInstaller(appContext)

    fun loadSurah(surah: Int): List<QuranAyah> {
        require(surah in 1..114) { "Surah must be between 1 and 114" }
        return withVerifiedDatabase { database ->
            database.rawQuery(
                "SELECT ayah, original_text FROM quran_ayah WHERE surah = ? ORDER BY ayah",
                arrayOf(surah.toString()),
            ).use { cursor ->
                buildList {
                    while (cursor.moveToNext()) {
                        add(
                            QuranAyah(
                                surah = surah,
                                ayah = cursor.getInt(0),
                                originalText = cursor.getString(1),
                            ),
                        )
                    }
                }
            }.also { ayahs ->
                check(ayahs.isNotEmpty()) { "Verified Quran pack returned no ayahs for Surah $surah" }
            }
        }
    }

    fun bundledNotice(): String =
        appContext.assets.open(QuranPackContract.ASSET_NOTICE).bufferedReader().use { it.readText() }

    private fun <T> withVerifiedDatabase(block: (SQLiteDatabase) -> T): T {
        val file = installer.ensureInstalled()
        val database = SQLiteDatabase.openDatabase(
            file.absolutePath,
            null,
            SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
        )
        return try {
            verifyMetadata(database)
            block(database)
        } finally {
            database.close()
        }
    }

    private fun verifyMetadata(database: SQLiteDatabase) {
        val expected = mapOf(
            "pack_id" to QuranPackContract.PACK_ID,
            "content_version" to QuranPackContract.CONTENT_VERSION,
            "source_sha256" to QuranPackContract.SOURCE_SHA256,
            "quran_coordinate_count" to QuranPackContract.RECORD_COUNT.toString(),
        )

        expected.forEach { (key, expectedValue) ->
            database.rawQuery(
                "SELECT value FROM pack_metadata WHERE key = ?",
                arrayOf(key),
            ).use { cursor ->
                check(cursor.moveToFirst()) { "Quran pack metadata is missing $key" }
                check(cursor.getString(0) == expectedValue) { "Quran pack metadata mismatch for $key" }
            }
        }
    }
}
