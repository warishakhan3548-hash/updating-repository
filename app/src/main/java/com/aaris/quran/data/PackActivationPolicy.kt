package com.aaris.quran.data

private val SHA256_HEX = Regex("^[0-9a-f]{64}$")

internal data class PackActivationState(
    val highestReleaseSequence: Long,
    val packSha256: String,
)

internal object PackActivationPolicy {
    fun accept(
        current: PackActivationState?,
        candidateSequence: Long,
        candidateSha256: String,
    ): PackActivationState {
        require(candidateSequence > 0L) {
            "release sequence must be positive"
        }
        require(SHA256_HEX.matches(candidateSha256)) {
            "pack SHA-256 must be lowercase hexadecimal"
        }

        if (current != null) {
            check(current.highestReleaseSequence > 0L && SHA256_HEX.matches(current.packSha256)) {
                "stored pack activation state is invalid"
            }
            check(candidateSequence >= current.highestReleaseSequence) {
                "content pack rollback blocked"
            }
            if (candidateSequence == current.highestReleaseSequence) {
                check(candidateSha256 == current.packSha256) {
                    "release sequence collision with different pack bytes"
                }
                return current
            }
        }

        return PackActivationState(
            highestReleaseSequence = candidateSequence,
            packSha256 = candidateSha256,
        )
    }
}

internal object PackActivationStateCodec {
    private const val FORMAT = "aaris-pack-activation-v1"

    fun encode(state: PackActivationState): ByteArray {
        val validated = PackActivationPolicy.accept(
            current = null,
            candidateSequence = state.highestReleaseSequence,
            candidateSha256 = state.packSha256,
        )
        return buildString {
            append(FORMAT)
            append('\n')
            append("release_sequence=")
            append(validated.highestReleaseSequence)
            append('\n')
            append("pack_sha256=")
            append(validated.packSha256)
            append('\n')
        }.toByteArray(Charsets.UTF_8)
    }

    fun decode(bytes: ByteArray): PackActivationState {
        val lines = bytes.toString(Charsets.UTF_8).split('\n')
        check(lines.size == 4 && lines.last().isEmpty()) {
            "invalid pack activation state framing"
        }
        check(lines[0] == FORMAT) {
            "unsupported pack activation state format"
        }

        val sequencePrefix = "release_sequence="
        val shaPrefix = "pack_sha256="
        check(lines[1].startsWith(sequencePrefix) && lines[2].startsWith(shaPrefix)) {
            "invalid pack activation state fields"
        }

        val sequence = lines[1].removePrefix(sequencePrefix).toLongOrNull()
        check(sequence != null) {
            "invalid stored release sequence"
        }
        val sha256 = lines[2].removePrefix(shaPrefix)

        return PackActivationPolicy.accept(
            current = null,
            candidateSequence = sequence,
            candidateSha256 = sha256,
        )
    }
}
