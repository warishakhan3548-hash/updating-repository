package com.aaris.quran.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.InputStream
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
        ensureVerifiedDatabase()
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
        check(manifest.getString("pack_id") == PACK_ID) {
            "Unexpected Quran pack id"
        }
        check(manifest.getString("content_version") == EXPECTED_CONTENT_VERSION) {
            "Unexpected Quran content-pack version"
        }
        check(manifest.getString("source_id") == EXPECTED_SOURCE_ID) {
            "Unexpected Quran source id"
        }
        check(manifest.getString("source_name") == EXPECTED_SOURCE_NAME) {
            "Unexpected Quran source name"
        }
        check(manifest.getString("source_version") == EXPECTED_SOURCE_VERSION) {
            "Unexpected Quran source version"
        }
        check(manifest.getString("source_sha256") == EXPECTED_SOURCE_SHA256) {
            "Unexpected Quran source SHA-256"
        }
        check(manifest.getString("built_sha256") == EXPECTED_DATABASE_SHA256) {
            "Unexpected Quran runtime-pack SHA-256"
        }
        check(manifest.getString("notice_sha256") == EXPECTED_NOTICE_SHA256) {
            "Unexpected Quran attribution-notice SHA-256"
        }
        check(manifest.getString("source_notice_sha256") == EXPECTED_NOTICE_SHA256) {
            "Runtime notice is not bound to the preserved source notice"
        }
        check(manifest.getInt("record_count") == 6236) {
            "Unexpected Quran ayah count in pack manifest"
        }
        check(sha256Asset(NOTICE_ASSET) == EXPECTED_NOTICE_SHA256) {
            "Bundled Quran attribution notice SHA-256 mismatch"
        }

        if (!databaseFile.isFile || sha256(databaseFile) != EXPECTED_DATABASE_SHA256) {
            databaseFile.parentFile?.mkdirs()
            val temp = File(databaseFile.parentFile, "${databaseFile.name}.tmp")
            temp.delete()
            appContext.assets.open(DATABASE_ASSET).use { input ->
                temp.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            check(sha256(temp) == EXPECTED_DATABASE_SHA256) {
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

    private fun sha256(file: File): String =
        file.inputStream().use { input -> sha256(input) }

    private fun sha256Asset(name: String): String =
        appContext.assets.open(name).use { input -> sha256(input) }

    private fun sha256(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString(separator = "") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }

    private companion object {
        const val PACK_ID = "quran-core"
        const val EXPECTED_CONTENT_VERSION = "1.0.3"
        const val EXPECTED_SOURCE_ID = "quran.tanzil.uthmani.v1.1"
        const val EXPECTED_SOURCE_NAME = "Tanzil Quran Text"
        const val EXPECTED_SOURCE_VERSION = "1.1"
        const val EXPECTED_SOURCE_SHA256 =
            "4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f"
        const val EXPECTED_DATABASE_SHA256 =
            "7acfb731c59ff2bc404752372eda8f30d16f38fa8c282aa4887ccb2fd8a2a025"
        const val EXPECTED_NOTICE_SHA256 =
            "d52680db446c36e9f7878c704e1db6eee16328f854671276fc63533fb73f3483"

        const val DATABASE_ASSET = "content.sqlite"
        const val MANIFEST_ASSET = "manifest.json"
        const val NOTICE_ASSET = "NOTICE.txt"
        const val DATABASE_FILE_NAME = "quran-core-1.0.3.sqlite"
    }
}
