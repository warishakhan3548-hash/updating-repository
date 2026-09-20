package com.aaris.quran.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

data class QuranAyah(
    val ayahId: String,
    val surah: Int,
    val ayah: Int,
    val originalText: String,
)

data class QuranPackInfo(
    val contentVersion: String,
    val sourceName: String,
    val sourceVersion: String,
    val reviewStatus: String,
)

class QuranPackStore(context: Context) {
    private val appContext = context.applicationContext
    private val databaseFile = File(appContext.noBackupFilesDir, DATABASE_FILE_NAME)

    @Volatile
    private var verifiedInProcess = false

    suspend fun loadSurah(surah: Int): List<QuranAyah> = withContext(Dispatchers.IO) {
        require(surah in 1..114) { "Surah must be between 1 and 114" }
        val database = openVerifiedDatabase()
        database.use { db ->
            db.rawQuery(
                """
                SELECT ayah_id, surah, ayah, original_text
                FROM quran_ayah
                WHERE surah = ?
                ORDER BY ayah ASC
                """.trimIndent(),
                arrayOf(surah.toString()),
            ).use { cursor ->
                buildList {
                    val idIndex = cursor.getColumnIndexOrThrow("ayah_id")
                    val surahIndex = cursor.getColumnIndexOrThrow("surah")
                    val ayahIndex = cursor.getColumnIndexOrThrow("ayah")
                    val textIndex = cursor.getColumnIndexOrThrow("original_text")
                    while (cursor.moveToNext()) {
                        add(
                            QuranAyah(
                                ayahId = cursor.getString(idIndex),
                                surah = cursor.getInt(surahIndex),
                                ayah = cursor.getInt(ayahIndex),
                                originalText = cursor.getString(textIndex),
                            ),
                        )
                    }
                }
            }
        }
    }

    suspend fun packInfo(): QuranPackInfo = withContext(Dispatchers.IO) {
        val manifest = readManifest()
        QuranPackInfo(
            contentVersion = manifest.getString("content_version"),
            sourceName = manifest.getString("source_name"),
            sourceVersion = manifest.getString("source_version"),
            reviewStatus = manifest.getString("review_status"),
        )
    }

    private fun openVerifiedDatabase(): SQLiteDatabase {
        ensureVerifiedDatabase()
        return SQLiteDatabase.openDatabase(
            databaseFile.absolutePath,
            null,
            SQLiteDatabase.OPEN_READONLY,
        )
    }

    @Synchronized
    private fun ensureVerifiedDatabase() {
        if (verifiedInProcess && databaseFile.isFile) {
            return
        }

        val manifest = readManifest()
        check(manifest.getString("pack_id") == "quran-core") {
            "Unexpected Quran pack id"
        }
        check(manifest.getInt("record_count") == 6236) {
            "Unexpected Quran ayah count in pack manifest"
        }

        val expectedHash = manifest.getString("built_sha256")
        if (!databaseFile.isFile || sha256(databaseFile) != expectedHash) {
            databaseFile.parentFile?.mkdirs()
            val temp = File(databaseFile.parentFile, "${databaseFile.name}.tmp")
            temp.delete()
            appContext.assets.open(DATABASE_ASSET).use { input ->
                temp.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            check(sha256(temp) == expectedHash) {
                temp.delete()
                "Bundled Quran pack SHA-256 mismatch"
            }
            if (databaseFile.exists()) {
                check(databaseFile.delete()) { "Unable to replace invalid Quran pack" }
            }
            check(temp.renameTo(databaseFile)) { "Unable to install verified Quran pack" }
        }

        verifiedInProcess = true
    }

    private fun readManifest(): JSONObject {
        val text = appContext.assets.open(MANIFEST_ASSET).bufferedReader().use { it.readText() }
        return JSONObject(text)
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    private companion object {
        const val DATABASE_ASSET = "content.sqlite"
        const val MANIFEST_ASSET = "manifest.json"
        const val DATABASE_FILE_NAME = "quran-core-1.0.1.sqlite"
    }
}
