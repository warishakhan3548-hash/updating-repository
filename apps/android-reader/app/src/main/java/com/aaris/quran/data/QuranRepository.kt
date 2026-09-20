package com.aaris.quran.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.aaris.quran.BuildConfig

data class QuranAyah(
    val ayahId: String,
    val surah: Int,
    val ayah: Int,
    val originalText: String,
)

class QuranRepository(
    private val context: Context,
) {
    @Volatile
    private var metadataVerified = false

    fun loadSurah(surah: Int): List<QuranAyah> {
        require(surah in 1..114) { "surah must be between 1 and 114" }
        val database = openVerifiedDatabase()
        return try {
            verifyMetadata(database)
            val rows = mutableListOf<QuranAyah>()
            database.rawQuery(READ_SURAH_SQL, arrayOf(surah.toString())).use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow("ayah_id")
                val surahIndex = cursor.getColumnIndexOrThrow("surah")
                val ayahIndex = cursor.getColumnIndexOrThrow("ayah")
                val originalTextIndex = cursor.getColumnIndexOrThrow("original_text")
                while (cursor.moveToNext()) {
                    rows += QuranAyah(
                        ayahId = cursor.getString(idIndex),
                        surah = cursor.getInt(surahIndex),
                        ayah = cursor.getInt(ayahIndex),
                        originalText = cursor.getString(originalTextIndex),
                    )
                }
            }
            if (rows.isEmpty()) {
                throw QuranPackException("Quran coordinate set is incomplete")
            }
            rows
        } finally {
            database.close()
        }
    }

    fun verifiedNotice(): String = QuranPack.verified(context).notice

    private fun openVerifiedDatabase(): SQLiteDatabase {
        val file = QuranPack.verified(context).database
        val database = SQLiteDatabase.openDatabase(
            file.absolutePath,
            null,
            SQLiteDatabase.OPEN_READONLY,
        )
        if (!database.isReadOnly) {
            database.close()
            throw QuranPackException("Quran content database must be read-only")
        }
        return database
    }

    private fun verifyMetadata(database: SQLiteDatabase) {
        if (metadataVerified) return
        synchronized(this) {
            if (metadataVerified) return

            val expected = mapOf(
                "pack_id" to BuildConfig.QURAN_PACK_ID,
                "schema_version" to "2",
                "content_version" to BuildConfig.QURAN_PACK_VERSION,
                "source_sha256" to BuildConfig.QURAN_SOURCE_SHA256,
                "source_notice_sha256" to BuildConfig.QURAN_NOTICE_SHA256,
            )
            val actual = mutableMapOf<String, String>()
            database.rawQuery(
                "SELECT key, value FROM pack_metadata WHERE key IN (?, ?, ?, ?, ?)",
                expected.keys.toTypedArray(),
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    actual[cursor.getString(0)] = cursor.getString(1)
                }
            }
            val mismatched = expected.filter { (key, value) -> actual[key] != value }.keys
            if (mismatched.isNotEmpty()) {
                throw QuranPackException(
                    "Quran pack metadata verification failed: ${mismatched.joinToString()}",
                )
            }
            metadataVerified = true
        }
    }

    companion object {
        internal const val READ_SURAH_SQL =
            """SELECT ayah_id, surah, ayah, original_text
               FROM quran_ayah
               WHERE surah = ?
               ORDER BY ayah"""
    }
}
