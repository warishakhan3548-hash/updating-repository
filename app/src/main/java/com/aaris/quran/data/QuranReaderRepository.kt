package com.aaris.quran.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.aaris.quran.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/**
 * Android platform adapter for the repository Reader Core contract.
 *
 * This class does not define Quran semantics. It only verifies the bundled content
 * pack, opens its SQLite artifact read-only, and projects source-faithful ayah text.
 */
data class AndroidReaderAyah(
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

class QuranReaderRepository(context: Context) {
    private val appContext = context.applicationContext
    private val databaseFile = File(appContext.noBackupFilesDir, DATABASE_FILE_NAME)

    @Volatile
    private var verifiedInProcess = false

    suspend fun loadSurah(surah: Int): List<AndroidReaderAyah> = withContext(Dispatchers.IO) {
        require(surah in 1..114) { "Surah must be between 1 and 114" }
        openVerifiedDatabase().use { database ->
            database.rawQuery(
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
                        val rowSurah = cursor.getInt(surahIndex)
                        val rowAyah = cursor.getInt(ayahIndex)
                        val ayahId = cursor.getString(idIndex)
                        check(ayahId == canonicalAyahId(rowSurah, rowAyah)) {
                            "Canonical ayah identity mismatch at $rowSurah:$rowAyah"
                        }
                        add(
                            AndroidReaderAyah(
                                ayahId = ayahId,
                                surah = rowSurah,
                                ayah = rowAyah,
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
        check(manifest.getInt("schema_version") == EXPECTED_MANIFEST_SCHEMA) {
            "Unexpected Quran pack manifest schema"
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
        check(manifest.getString("source_licence_sha256") == EXPECTED_SOURCE_LICENCE_SHA256) {
            "Unexpected Quran source licence SHA-256"
        }
        check(manifest.getString("source_provenance_sha256") == EXPECTED_SOURCE_PROVENANCE_SHA256) {
            "Unexpected Quran source provenance SHA-256"
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
        check(manifest.getInt("record_count") == EXPECTED_AYAH_COUNT) {
            "Unexpected Quran ayah count in pack manifest"
        }

        val reviewStatus = manifest.getString("review_status")
        check(reviewStatus in setOf("candidate", "reviewed", "approved")) {
            "Unexpected Quran pack review status"
        }
        if (!BuildConfig.DEBUG) {
            check(reviewStatus == "approved") {
                "Reader refuses an unapproved Quran pack outside development"
            }
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
        file.inputStream().use(::sha256)

    private fun sha256Asset(name: String): String =
        appContext.assets.open(name).use(::sha256)

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

    private fun canonicalAyahId(surah: Int, ayah: Int): String =
        "qa:%03d:%03d".format(surah, ayah)

    private companion object {
        const val PACK_ID = "quran-core"
        const val EXPECTED_MANIFEST_SCHEMA = 2
        const val EXPECTED_CONTENT_VERSION = "1.0.4"
        const val EXPECTED_SOURCE_ID = "quran.tanzil.uthmani.v1.1"
        const val EXPECTED_SOURCE_NAME = "Tanzil Quran Text"
        const val EXPECTED_SOURCE_VERSION = "1.1"
        const val EXPECTED_AYAH_COUNT = 6236

        const val EXPECTED_SOURCE_SHA256 =
            "4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f"
        const val EXPECTED_SOURCE_LICENCE_SHA256 =
            "1ef7fbb0454f64ed4cceb838337808969711155f36147d1b357fc083336f4c68"
        const val EXPECTED_SOURCE_PROVENANCE_SHA256 =
            "733a938c4f54f082bf7f4e0b1d9bff7ce21afedceeba199294e872a428a57505"
        const val EXPECTED_DATABASE_SHA256 =
            "492fcc4caa33b5ba64c94abce4d5f78d00232a99b777ea5e3bd70c338e19fa09"
        const val EXPECTED_NOTICE_SHA256 =
            "d52680db446c36e9f7878c704e1db6eee16328f854671276fc63533fb73f3483"

        const val DATABASE_ASSET = "content.sqlite"
        const val MANIFEST_ASSET = "manifest.json"
        const val NOTICE_ASSET = "NOTICE.txt"
        const val DATABASE_FILE_NAME = "quran-core-1.0.4.sqlite"
    }
}
