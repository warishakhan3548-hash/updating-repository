package com.aaris.quran.data

import android.content.Context
import java.io.File
import java.io.FileOutputStream

internal class QuranPackInstaller(private val context: Context) {
    @Volatile
    private var verifiedPack: File? = null

    @Synchronized
    fun ensureInstalled(): File {
        verifiedPack?.let { cached ->
            if (cached.isFile && cached.length() == QuranPackContract.BUILT_BYTE_SIZE) return cached
            verifiedPack = null
        }

        val packDir = File(
            context.filesDir,
            "content-packs/${QuranPackContract.PACK_ID}/${QuranPackContract.CONTENT_VERSION}",
        )
        check(packDir.exists() || packDir.mkdirs()) { "Unable to create Quran pack directory" }

        val target = File(packDir, "content.sqlite")
        if (target.isVerifiedPack()) return target.also { verifiedPack = it }

        val candidate = File(packDir, "content.sqlite.tmp")
        if (candidate.exists()) check(candidate.delete()) { "Unable to clear stale Quran pack candidate" }

        context.assets.open(QuranPackContract.ASSET_DATABASE).use { input ->
            FileOutputStream(candidate).use { output -> input.copyTo(output) }
        }

        check(candidate.isVerifiedPack()) { "Bundled Quran pack failed integrity verification" }
        if (target.exists()) check(target.delete()) { "Unable to replace invalid Quran pack" }
        check(candidate.renameTo(target)) { "Unable to activate verified Quran pack" }
        check(target.setReadOnly()) { "Unable to mark Quran pack read-only" }

        verifiedPack = target
        return target
    }

    private fun File.isVerifiedPack(): Boolean =
        isFile &&
            length() == QuranPackContract.BUILT_BYTE_SIZE &&
            Sha256.of(this) == QuranPackContract.BUILT_SHA256
}
