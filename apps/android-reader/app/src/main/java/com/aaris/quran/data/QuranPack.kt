package com.aaris.quran.data

import android.content.Context
import com.aaris.quran.BuildConfig
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

object QuranPack {
    private const val DATABASE_ASSET = "content.sqlite"
    private const val MANIFEST_ASSET = "manifest.json"
    private const val NOTICE_ASSET = "NOTICE.txt"

    data class VerifiedPack(
        val database: File,
        val notice: String,
    )

    @Volatile
    private var cached: VerifiedPack? = null

    fun verified(context: Context): VerifiedPack {
        cached?.let { return it }
        return synchronized(this) {
            cached?.let { return@synchronized it }
            verifyManifest(context)
            val notice = readVerifiedNotice(context)
            val database = installVerifiedDatabase(context)
            VerifiedPack(database = database, notice = notice).also { cached = it }
        }
    }

    private fun verifyManifest(context: Context) {
        val manifestText = context.assets.open(MANIFEST_ASSET)
            .bufferedReader(Charsets.UTF_8)
            .use { it.readText() }
        val manifest = JSONObject(manifestText)

        requireEqual("pack_id", manifest.getString("pack_id"), BuildConfig.QURAN_PACK_ID)
        requireEqual(
            "content_version",
            manifest.getString("content_version"),
            BuildConfig.QURAN_PACK_VERSION,
        )
        requireEqual(
            "review_status",
            manifest.getString("review_status"),
            BuildConfig.QURAN_PACK_REVIEW_STATUS,
        )
        requireEqual(
            "built_sha256",
            manifest.getString("built_sha256"),
            BuildConfig.QURAN_PACK_SHA256,
        )
        requireEqual(
            "source_sha256",
            manifest.getString("source_sha256"),
            BuildConfig.QURAN_SOURCE_SHA256,
        )
        requireEqual(
            "notice_sha256",
            manifest.getString("notice_sha256"),
            BuildConfig.QURAN_NOTICE_SHA256,
        )
        if (manifest.getInt("schema_version") != 2) {
            throw QuranPackException("Unsupported Quran pack manifest schema")
        }
        if (manifest.getString("review_status") != "approved" && !BuildConfig.DEBUG) {
            throw QuranPackException("Unapproved Quran pack is blocked outside debug builds")
        }
    }

    private fun readVerifiedNotice(context: Context): String {
        val bytes = context.assets.open(NOTICE_ASSET).use { it.readBytes() }
        if (sha256(bytes) != BuildConfig.QURAN_NOTICE_SHA256) {
            throw QuranPackException("Quran source notice integrity check failed")
        }
        return bytes.toString(Charsets.UTF_8)
    }

    private fun installVerifiedDatabase(context: Context): File {
        val directory = File(context.filesDir, "quran-packs/${BuildConfig.QURAN_PACK_VERSION}")
        if (!directory.exists() && !directory.mkdirs()) {
            throw QuranPackException("Unable to create local Quran pack directory")
        }

        val target = File(directory, "content.sqlite")
        if (target.isFile && sha256(target) == BuildConfig.QURAN_PACK_SHA256) {
            return target
        }

        if (target.exists() && !target.delete()) {
            throw QuranPackException("Unable to replace an invalid local Quran pack")
        }

        val temporary = File(directory, "content.sqlite.tmp")
        if (temporary.exists()) temporary.delete()

        FileOutputStream(temporary).use { output ->
            context.assets.open(DATABASE_ASSET).use { input ->
                input.copyTo(output)
            }
            output.fd.sync()
        }

        if (sha256(temporary) != BuildConfig.QURAN_PACK_SHA256) {
            temporary.delete()
            throw QuranPackException("Quran content integrity check failed")
        }
        if (!temporary.renameTo(target)) {
            temporary.delete()
            throw QuranPackException("Unable to activate verified Quran content")
        }
        return target
    }

    private fun requireEqual(field: String, actual: String, expected: String) {
        if (actual != expected) {
            throw QuranPackException("Quran pack $field does not match the pinned build contract")
        }
    }

    private fun sha256(file: File): String =
        file.inputStream().use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read > 0) digest.update(buffer, 0, read)
            }
            digest.digest().toHex()
        }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    private fun ByteArray.toHex(): String = joinToString(separator = "") { "%02x".format(it) }
}

class QuranPackException(message: String) : IllegalStateException(message)
