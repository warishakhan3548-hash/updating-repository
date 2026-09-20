package com.aaris.quran.data

import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.nio.charset.StandardCharsets

internal object ReleaseSequencePolicy {
    fun requireAcceptable(highestAccepted: Long, candidate: Long) {
        require(highestAccepted >= 0L) { "highest accepted release sequence cannot be negative" }
        require(candidate > 0L) { "release sequence must be positive" }
        check(candidate >= highestAccepted) {
            "Quran content rollback rejected: release sequence $candidate is below already accepted $highestAccepted"
        }
    }
}

internal class ReleaseSequenceStore(
    stateDirectory: File,
) {
    private val stateFile: AtomicFile

    init {
        check(stateDirectory.exists() || stateDirectory.mkdirs()) {
            "Cannot create Quran trust-state directory"
        }
        stateFile = AtomicFile(File(stateDirectory, "quran-core.release-sequence"))
    }

    fun highestAccepted(): Long = synchronized(PROCESS_LOCK) {
        readHighestAccepted()
    }

    fun requireAcceptable(candidate: Long) = synchronized(PROCESS_LOCK) {
        ReleaseSequencePolicy.requireAcceptable(readHighestAccepted(), candidate)
    }

    fun recordAccepted(candidate: Long) = synchronized(PROCESS_LOCK) {
        val current = readHighestAccepted()
        ReleaseSequencePolicy.requireAcceptable(current, candidate)
        if (candidate == current) return@synchronized

        val stream = stateFile.startWrite()
        try {
            stream.write("$candidate\n".toByteArray(StandardCharsets.US_ASCII))
            stateFile.finishWrite(stream)
        } catch (error: Throwable) {
            runCatching { stateFile.failWrite(stream) }
            throw error
        }
    }

    private fun readHighestAccepted(): Long {
        val bytes = try {
            stateFile.readFully()
        } catch (_: FileNotFoundException) {
            return 0L
        }

        val text = String(bytes, StandardCharsets.US_ASCII)
        check(RECORD.matches(text)) {
            "Stored Quran release sequence is corrupt"
        }
        val value = text.trimEnd('\n').toLongOrNull()
        check(value != null && value > 0L) {
            "Stored Quran release sequence is invalid"
        }
        return value
    }

    private companion object {
        val RECORD = Regex("[1-9][0-9]*\\n?")
        val PROCESS_LOCK = Any()
    }
}
