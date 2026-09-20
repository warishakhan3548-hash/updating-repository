package com.aaris.quran.security

import android.content.Context
import android.util.AtomicFile
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

data class ContentPackAcceptanceRecord(
    val releaseSequence: Long,
    val manifestSha256: String,
    val contentSha256: String,
)

internal enum class ContentPackAcceptanceDecision {
    ACCEPT_FIRST,
    ACCEPT_IDENTICAL,
    ACCEPT_ADVANCE,
    REJECT_ROLLBACK,
    REJECT_EQUIVOCATION,
}

internal fun evaluateContentPackAcceptance(
    previous: ContentPackAcceptanceRecord?,
    candidate: ContentPackAcceptanceRecord,
): ContentPackAcceptanceDecision = when {
    previous == null -> ContentPackAcceptanceDecision.ACCEPT_FIRST
    candidate.releaseSequence < previous.releaseSequence ->
        ContentPackAcceptanceDecision.REJECT_ROLLBACK
    candidate.releaseSequence > previous.releaseSequence ->
        ContentPackAcceptanceDecision.ACCEPT_ADVANCE
    candidate.manifestSha256 == previous.manifestSha256 &&
        candidate.contentSha256 == previous.contentSha256 ->
        ContentPackAcceptanceDecision.ACCEPT_IDENTICAL
    else -> ContentPackAcceptanceDecision.REJECT_EQUIVOCATION
}

class ContentPackAcceptanceStore(context: Context) {
    private val noBackupRoot = context.applicationContext.noBackupFilesDir
    fun checkAndRecord(
        packId: String,
        releaseSequence: Long,
        manifestSha256: String,
        contentSha256: String,
    ) = synchronized(PROCESS_LOCK) {
        validatePackId(packId)
        val candidate = ContentPackAcceptanceRecord(
            releaseSequence = releaseSequence,
            manifestSha256 = manifestSha256,
            contentSha256 = contentSha256,
        )
        validateRecord(candidate)

        val atomicFile = atomicFileFor(packId)
        val previous = readRecord(atomicFile, packId)
        when (evaluateContentPackAcceptance(previous, candidate)) {
            ContentPackAcceptanceDecision.ACCEPT_IDENTICAL -> Unit
            ContentPackAcceptanceDecision.ACCEPT_FIRST,
            ContentPackAcceptanceDecision.ACCEPT_ADVANCE -> writeRecord(
                atomicFile,
                packId,
                candidate,
            )
            ContentPackAcceptanceDecision.REJECT_ROLLBACK ->
                throw SecurityException(
                    "Rejected rollback of $packId from release sequence " +
                        "${previous!!.releaseSequence} to ${candidate.releaseSequence}",
                )
            ContentPackAcceptanceDecision.REJECT_EQUIVOCATION ->
                throw SecurityException(
                    "Rejected conflicting $packId bytes for already accepted " +
                        "release sequence ${candidate.releaseSequence}",
                )
        }
    }

    private fun atomicFileFor(packId: String): AtomicFile {
        val directory = File(noBackupRoot, "security/content-pack-acceptance")
        check(directory.exists() || directory.mkdirs()) {
            "Cannot create content-pack acceptance-state directory"
        }
        return AtomicFile(File(directory, "$packId.bin"))
    }

    private fun readRecord(
        atomicFile: AtomicFile,
        expectedPackId: String,
    ): ContentPackAcceptanceRecord? {
        val stream = try {
            atomicFile.openRead()
        } catch (_: FileNotFoundException) {
            return null
        } catch (error: IOException) {
            throw SecurityException("Cannot read content-pack acceptance state", error)
        }

        try {
            DataInputStream(stream).use { input ->
                val magic = input.readInt()
                val version = input.readInt()
                val packId = input.readUTF()
                val record = ContentPackAcceptanceRecord(
                    releaseSequence = input.readLong(),
                    manifestSha256 = input.readUTF(),
                    contentSha256 = input.readUTF(),
                )

                if (magic != FORMAT_MAGIC || version != FORMAT_VERSION) {
                    throw SecurityException("Unsupported content-pack acceptance-state format")
                }
                if (packId != expectedPackId) {
                    throw SecurityException("Content-pack acceptance-state identity mismatch")
                }
                if (input.read() != -1) {
                    throw SecurityException("Trailing bytes in content-pack acceptance state")
                }
                try {
                    validateRecord(record)
                } catch (error: IllegalArgumentException) {
                    throw SecurityException("Invalid content-pack acceptance state", error)
                }
                return record
            }
        } catch (error: SecurityException) {
            throw error
        } catch (error: IOException) {
            throw SecurityException("Cannot parse content-pack acceptance state", error)
        }
    }

    private fun writeRecord(
        atomicFile: AtomicFile,
        packId: String,
        record: ContentPackAcceptanceRecord,
    ) {
        val stream = try {
            atomicFile.startWrite()
        } catch (error: IOException) {
            throw SecurityException("Cannot start content-pack acceptance-state write", error)
        }

        try {
            val output = DataOutputStream(stream)
            output.writeInt(FORMAT_MAGIC)
            output.writeInt(FORMAT_VERSION)
            output.writeUTF(packId)
            output.writeLong(record.releaseSequence)
            output.writeUTF(record.manifestSha256)
            output.writeUTF(record.contentSha256)
            output.flush()
            atomicFile.finishWrite(stream)
        } catch (error: Exception) {
            atomicFile.failWrite(stream)
            throw SecurityException("Cannot commit content-pack acceptance state", error)
        }
    }

    private fun validatePackId(packId: String) {
        require(PACK_ID.matches(packId)) { "Invalid content-pack id" }
    }

    private fun validateRecord(record: ContentPackAcceptanceRecord) {
        require(record.releaseSequence > 0L) { "release sequence must be positive" }
        require(SHA256.matches(record.manifestSha256)) { "invalid manifest SHA-256" }
        require(SHA256.matches(record.contentSha256)) { "invalid content SHA-256" }
    }

    private companion object {
        val PROCESS_LOCK = Any()
        const val FORMAT_MAGIC = 0x41435041
        const val FORMAT_VERSION = 1
        val PACK_ID = Regex("^[a-z0-9][a-z0-9._-]{0,63}$")
        val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}
