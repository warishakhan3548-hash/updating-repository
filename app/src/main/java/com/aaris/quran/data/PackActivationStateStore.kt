package com.aaris.quran.data

import android.content.Context
import android.util.AtomicFile
import java.io.File

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

    fun accept(
        releaseSequence: Long,
        packSha256: String,
    ) {
        val current = read()
        val next = PackActivationPolicy.accept(
            current = current,
            candidateSequence = releaseSequence,
            candidateSha256 = packSha256,
        )
        if (next == current) return

        val output = atomicFile.startWrite()
        try {
            output.write(PackActivationStateCodec.encode(next))
            atomicFile.finishWrite(output)
        } catch (failure: Throwable) {
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
