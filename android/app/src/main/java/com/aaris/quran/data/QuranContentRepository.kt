package com.aaris.quran.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.aaris.quran.BuildConfig
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.security.MessageDigest

data class QuranAyah(
    val ayahId: String,
    val ayah: Int,
    val originalText: String,
)

class QuranContentRepository(
    private val context: Context,
) : Closeable {
    private val lock = Any()

    @Volatile
    private var database: SQLiteDatabase? = null

    fun loadSurah(surah: Int): List<QuranAyah> {
        require(surah in 1..114) { "Surah must be between 1 and 114" }
        val result = ArrayList<QuranAyah>()
        database().query(
            "quran_ayah",
            arrayOf("ayah_id", "ayah", "original_text"),
            "surah = ?",
            arrayOf(surah.toString()),
            null,
            null,
            "ayah ASC",
        ).use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow("ayah_id")
            val ayahIndex = cursor.getColumnIndexOrThrow("ayah")
            val textIndex = cursor.getColumnIndexOrThrow("original_text")
            while (cursor.moveToNext()) {
                result += QuranAyah(
                    ayahId = cursor.getString(idIndex),
                    ayah = cursor.getInt(ayahIndex),
                    originalText = cursor.getString(textIndex),
                )
            }
        }
        check(result.isNotEmpty()) { "Pinned Quran pack returned no ayahs for Surah " + surah }
        return result
    }

    private fun database(): SQLiteDatabase {
        database?.let { if (it.isOpen) return it }
        return synchronized(lock) {
            database?.let { if (it.isOpen) return@synchronized it }
            val file = materializeVerifiedPack()
            val opened = SQLiteDatabase.openDatabase(
                file.path,
                null,
                SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
            )
            validateMetadata(opened)
            database = opened
            opened
        }
    }

    private fun materializeVerifiedPack(): File {
        val target = File(
            context.noBackupFilesDir,
            "quran-core-" + BuildConfig.QURAN_PACK_VERSION + ".sqlite",
        )
        if (target.isFile && sha256(target) == BuildConfig.QURAN_PACK_SHA256) {
            return target
        }

        if (target.exists() && !target.delete()) {
            throw IOException("Could not replace invalid local Quran pack")
        }

        val temporary = File(target.parentFile, target.name + ".tmp")
        if (temporary.exists() && !temporary.delete()) {
            throw IOException("Could not clear temporary Quran pack")
        }
        context.assets.open("content.sqlite").use { input ->
            temporary.outputStream().buffered().use { output ->
                input.copyTo(output, DEFAULT_BUFFER_SIZE)
            }
        }

        val actual = sha256(temporary)
        if (actual != BuildConfig.QURAN_PACK_SHA256) {
            temporary.delete()
            throw SecurityException("Bundled Quran pack failed SHA-256 verification")
        }

        if (!temporary.renameTo(target)) {
            temporary.delete()
            throw IOException("Could not atomically activate verified Quran pack")
        }
        target.setReadOnly()
        return target
    }

    private fun validateMetadata(db: SQLiteDatabase) {
        val version = packMetadata(db, "content_version")
        val sourceId = packMetadata(db, "source_id")
        val sourceHash = packMetadata(db, "source_sha256")
        check(version == BuildConfig.QURAN_PACK_VERSION) {
            "Quran pack version metadata mismatch"
        }
        check(sourceId == "quran.tanzil.uthmani.v1.1") {
            "Unexpected Quran evidence source"
        }
        check(sourceHash == "4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f") {
            "Quran source SHA-256 metadata mismatch"
        }
    }

    private fun packMetadata(db: SQLiteDatabase, key: String): String {
        db.rawQuery(
            "SELECT value FROM pack_metadata WHERE key = ? LIMIT 1",
            arrayOf(key),
        ).use { cursor ->
            check(cursor.moveToFirst()) { "Missing Quran pack metadata: " + key }
            return cursor.getString(0)
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    override fun close() {
        synchronized(lock) {
            database?.close()
            database = null
        }
    }
}
