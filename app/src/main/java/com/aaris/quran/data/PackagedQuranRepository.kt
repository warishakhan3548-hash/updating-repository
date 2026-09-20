package com.aaris.quran.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.aaris.quran.BuildConfig
import com.aaris.quran.model.QuranAyah
import com.aaris.quran.security.ContentPackAcceptanceStore
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class PackagedQuranRepository(
    private val context: Context,
) : QuranRepository {
    private val acceptanceStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        ContentPackAcceptanceStore(context)
    }

    private val installedPack: File by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        require(BuildConfig.DEBUG || BuildConfig.QURAN_PACK_RELEASE_READY) {
            "Production reader refuses an unapproved or unsigned Quran pack"
        }
        installVerifiedPack()
    }

    override suspend fun ayahsForSurah(surah: Int): List<QuranAyah> =
        withContext(Dispatchers.IO) {
            require(surah in 1..114) { "surah must be between 1 and 114" }
            val database = SQLiteDatabase.openDatabase(
                installedPack.absolutePath,
                null,
                SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
            )
            try {
                database.rawQuery(
                    """
                    SELECT ayah_id, surah, ayah, original_text
                    FROM quran_ayah
                    WHERE surah = ?
                    ORDER BY ayah
                    """.trimIndent(),
                    arrayOf(surah.toString()),
                ).use { cursor ->
                    val ayahIdIndex = cursor.getColumnIndexOrThrow("ayah_id")
                    val surahIndex = cursor.getColumnIndexOrThrow("surah")
                    val ayahIndex = cursor.getColumnIndexOrThrow("ayah")
                    val originalTextIndex = cursor.getColumnIndexOrThrow("original_text")
                    buildList {
                        while (cursor.moveToNext()) {
                            add(
                                QuranAyah(
                                    ayahId = cursor.getString(ayahIdIndex),
                                    surah = cursor.getInt(surahIndex),
                                    ayah = cursor.getInt(ayahIndex),
                                    originalText = cursor.getString(originalTextIndex),
                                ),
                            )
                        }
                    }.also { ayahs ->
                        check(ayahs.isNotEmpty()) {
                            "Verified Quran pack does not contain Surah $surah"
                        }
                        ayahs.forEachIndexed { index, ayah ->
                            check(ayah.ayahId == "qa:%03d:%03d".format(surah, index + 1)) {
                                "Canonical ayah identity mismatch in packaged Quran"
                            }
                        }
                    }
                }
            } finally {
                database.close()
            }
        }

    private fun installVerifiedPack(): File {
        val directory = File(
            context.noBackupFilesDir,
            "content/quran-core/${BuildConfig.QURAN_PACK_VERSION}",
        )
        check(directory.exists() || directory.mkdirs()) {
            "Cannot create local Quran content directory"
        }

        val target = File(directory, "content.sqlite")
        if (target.isFile && target.sha256() == BuildConfig.QURAN_PACK_SHA256) {
            recordReleaseAcceptanceIfNeeded()
            return target
        }

        val temporary = File(directory, "content.sqlite.tmp")
        temporary.delete()
        context.assets.open("content.sqlite").use { input ->
            temporary.outputStream().use { output -> input.copyTo(output) }
        }

        val actualSha = temporary.sha256()
        check(actualSha == BuildConfig.QURAN_PACK_SHA256) {
            temporary.delete()
            "Bundled Quran pack failed SHA-256 verification"
        }

        if (target.exists()) {
            check(target.delete()) { "Cannot replace invalid local Quran pack" }
        }
        check(temporary.renameTo(target)) { "Cannot activate verified local Quran pack" }
        check(target.sha256() == BuildConfig.QURAN_PACK_SHA256) {
            "Activated Quran pack failed post-rename SHA-256 verification"
        }
        recordReleaseAcceptanceIfNeeded()
        return target
    }

    private fun recordReleaseAcceptanceIfNeeded() {
        if (!BuildConfig.QURAN_PACK_RELEASE_READY) return

        check(BuildConfig.QURAN_PACK_RELEASE_SEQUENCE > 0L) {
            "Approved Quran pack is missing a positive signed release sequence"
        }
        acceptanceStore.checkAndRecord(
            packId = BuildConfig.QURAN_PACK_ID,
            releaseSequence = BuildConfig.QURAN_PACK_RELEASE_SEQUENCE,
            manifestSha256 = BuildConfig.QURAN_PACK_MANIFEST_SHA256,
            contentSha256 = BuildConfig.QURAN_PACK_SHA256,
        )
    }

    private fun File.sha256(): String {
        val digest = MessageDigest.getInstance("SHA-256")
        inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }
}
