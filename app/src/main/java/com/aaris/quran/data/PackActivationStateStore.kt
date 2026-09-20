package com.aaris.quran.data

import android.content.Context
import android.util.AtomicFile
import java.io.File

internal val PACK_ACTIVATION_PROCESS_LOCK = Any()

internal class PackActivationStateStore(
    context: Context,
) {
    private val stateFile = File(
        context.noBackupFilesDir,
        "content/activation/quran-core.state",
    )
    private val atomicFile: AtomicFile

    init {
        val parent = checkNotNull(stateFile.parentFile)
        check(parent.exists() || parent.mkdirs()) {
            "cannot create content activation state directory"
        }
        atomicFile = AtomicFile(stateFile)
    }

    fun requireAcceptable(
        releaseSequence: Long,
        packSha256: String,
    ) = synchronized(PACK_ACTIVATION_PROCESS_LOCK) {
        PackActivationPolicy.accept(
            current = read(),
            candidateSequence = releaseSequence,
            candidateSha256 = packSha256,
        )
    }

    fun accept(
        releaseSequence: Long,
        packSha256: String,
    ) = synchronized(PACK_ACTIVATION_PROCESS_LOCK) {
        val current = read()
        val next = PackActivationPolicy.accept(
            current = current,
            candidateSequence = releaseSequence,
            candidateSha256 = packSha256,
        )
        if (next == current) return@synchronized

        val output = atomicFile.startWrite()
        try {
            output.write(PackActivationStateCodec.encode(next))
            atomicFile.finishWrite(output)
        } catch (failure: Exception) {
            atomicFile.failWrite(output)
            throw failure
        }
    }

    private fun read(): PackActivationState? {
        if (!stateFile.exists()) return null
        return atomicFile.openRead().use { input ->
            PackActivationStateCodec.decode(input.readBytes())
        }
    }
}
