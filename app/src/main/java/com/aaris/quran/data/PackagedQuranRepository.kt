package com.aaris.quran.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.AtomicFile
import com.aaris.quran.BuildConfig
import com.aaris.quran.model.QuranAyah
import com.aaris.quran.model.QuranSearchHit
import com.aaris.quran.model.QuranSearchMatchKind
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class PackagedQuranRepository(
    private val context: Context,
) : QuranRepository {
    private val activationStateStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        PackActivationStateStore(context)
    }

    private val installedPack: File by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        synchronized(PACK_ACTIVATION_PROCESS_LOCK) {
            require(BuildConfig.DEBUG || BuildConfig.QURAN_PACK_RELEASE_READY) {
                "Production reader refuses an unapproved or unsigned Quran pack"
            }

            val releaseSequence = if (BuildConfig.DEBUG) {
                null
            } else {
                check(BuildConfig.QURAN_PACK_RELEASE_READY) {
                    "Release reader requires an approved Quran pack"
                }
                val candidate = BuildConfig.QURAN_PACK_RELEASE_SEQUENCE
                check(candidate in 1..MAX_SIGNED_RELEASE_SEQUENCE) {
                    "Approved Quran pack is missing a valid signed release sequence"
                }
                activationStateStore.requireAcceptable(
                    releaseSequence = candidate,
                    packSha256 = BuildConfig.QURAN_PACK_SHA256,
                )
                candidate
            }

            val installed = installVerifiedPack()
            releaseSequence?.let { accepted ->
                activationStateStore.accept(
                    releaseSequence = accepted,
                    packSha256 = BuildConfig.QURAN_PACK_SHA256,
                )
            }
            installed
        }
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


    override suspend fun searchAyahs(
        query: String,
        limit: Int,
    ): List<QuranSearchHit> = withContext(Dispatchers.IO) {
        require(limit in 1..100) { "search limit must be between 1 and 100" }

        val unicodeQuery = ArabicSearchNormalizer.normalizeUnicode(query).trim()
        val diacriticFreeQuery = ArabicSearchNormalizer.normalizeDiacriticFree(query)
        if (diacriticFreeQuery.isBlank()) return@withContext emptyList()

        val database = SQLiteDatabase.openDatabase(
            installedPack.absolutePath,
            null,
            SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
        )
        try {
            database.rawQuery(
                "SELECT value FROM pack_metadata WHERE key = 'search_normalization_version'",
                null,
            ).use { cursor ->
                check(cursor.moveToFirst()) {
                    "Verified Quran pack is missing its search normalization version"
                }
                check(cursor.getString(0) == ArabicSearchNormalizer.VERSION) {
                    "Quran search normalization version mismatch"
                }
            }

            val strictHits = database.rawQuery(
                """
                SELECT ayah_id, surah, ayah, original_text
                FROM quran_ayah
                WHERE instr(search_unicode, ?) > 0
                   OR instr(search_diacritic_free, ?) > 0
                ORDER BY
                    CASE
                        WHEN search_unicode = ? THEN 0
                        WHEN instr(search_unicode, ?) = 1 THEN 1
                        WHEN search_diacritic_free = ? THEN 2
                        WHEN instr(search_diacritic_free, ?) = 1 THEN 3
                        ELSE 4
                    END,
                    length(search_diacritic_free),
                    surah,
                    ayah
                LIMIT ?
                """.trimIndent(),
                arrayOf(
                    unicodeQuery,
                    diacriticFreeQuery,
                    unicodeQuery,
                    unicodeQuery,
                    diacriticFreeQuery,
                    diacriticFreeQuery,
                    limit.toString(),
                ),
            ).use { cursor ->
                val ayahIdIndex = cursor.getColumnIndexOrThrow("ayah_id")
                val surahIndex = cursor.getColumnIndexOrThrow("surah")
                val ayahIndex = cursor.getColumnIndexOrThrow("ayah")
                val originalTextIndex = cursor.getColumnIndexOrThrow("original_text")
                buildList {
                    while (cursor.moveToNext()) {
                        add(
                            QuranSearchHit(
                                ayah = QuranAyah(
                                    ayahId = cursor.getString(ayahIdIndex),
                                    surah = cursor.getInt(surahIndex),
                                    ayah = cursor.getInt(ayahIndex),
                                    originalText = cursor.getString(originalTextIndex),
                                ),
                                matchKind = QuranSearchMatchKind.STRICT,
                            ),
                        )
                    }
                }
            }
            if (strictHits.isNotEmpty()) return@withContext strictHits

            val compatibilityQuery = ArabicSearchNormalizer.normalizeCompatibility(query)
            if (compatibilityQuery.isBlank()) return@withContext emptyList()

            val compatibilityExpression =
                "replace(replace(replace(replace(replace(replace(" +
                    "search_diacritic_free, 'ٱ', 'ا'), 'أ', 'ا'), 'إ', 'ا'), " +
                    "'آ', 'ا'), 'ی', 'ي'), 'ہ', 'ه')"

            database.rawQuery(
                """
                WITH compatibility_candidates AS (
                    SELECT
                        ayah_id,
                        surah,
                        ayah,
                        original_text,
                        $compatibilityExpression AS compatibility_text
                    FROM quran_ayah
                )
                SELECT ayah_id, surah, ayah, original_text
                FROM compatibility_candidates
                WHERE instr(compatibility_text, ?) > 0
                ORDER BY
                    CASE
                        WHEN compatibility_text = ? THEN 0
                        WHEN instr(compatibility_text, ?) = 1 THEN 1
                        ELSE 2
                    END,
                    length(compatibility_text),
                    surah,
                    ayah
                LIMIT ?
                """.trimIndent(),
                arrayOf(
                    compatibilityQuery,
                    compatibilityQuery,
                    compatibilityQuery,
                    limit.toString(),
                ),
            ).use { cursor ->
                val ayahIdIndex = cursor.getColumnIndexOrThrow("ayah_id")
                val surahIndex = cursor.getColumnIndexOrThrow("surah")
                val ayahIndex = cursor.getColumnIndexOrThrow("ayah")
                val originalTextIndex = cursor.getColumnIndexOrThrow("original_text")
                buildList {
                    while (cursor.moveToNext()) {
                        add(
                            QuranSearchHit(
                                ayah = QuranAyah(
                                    ayahId = cursor.getString(ayahIdIndex),
                                    surah = cursor.getInt(surahIndex),
                                    ayah = cursor.getInt(ayahIndex),
                                    originalText = cursor.getString(originalTextIndex),
                                ),
                                matchKind = QuranSearchMatchKind.COMPATIBILITY,
                            ),
                        )
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
            return target
        }

        val temporary = File(directory, "content.sqlite.verified.tmp")
        temporary.delete()
        context.assets.open("content.sqlite").use { input ->
            temporary.outputStream().use { output -> input.copyTo(output) }
        }

        val actualSha = temporary.sha256()
        check(actualSha == BuildConfig.QURAN_PACK_SHA256) {
            temporary.delete()
            "Bundled Quran pack failed SHA-256 verification"
        }

        val atomicTarget = AtomicFile(target)
        val output = atomicTarget.startWrite()
        try {
            temporary.inputStream().use { input -> input.copyTo(output) }
            atomicTarget.finishWrite(output)
        } catch (failure: Throwable) {
            atomicTarget.failWrite(output)
            throw failure
        } finally {
            temporary.delete()
        }

        check(target.isFile && target.sha256() == BuildConfig.QURAN_PACK_SHA256) {
            "Activated Quran pack failed post-write SHA-256 verification"
        }
        return target
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