package com.aaris.quran.data

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PackActivationPolicyTest {
    private val shaA = "a".repeat(64)
    private val shaB = "b".repeat(64)

    @Test
    fun firstAcceptedReleaseBecomesHighestKnownSequence() {
        val accepted = PackActivationPolicy.accept(
            current = null,
            candidateSequence = 7L,
            candidateSha256 = shaA,
        )

        assertEquals(7L, accepted.highestReleaseSequence)
        assertEquals(shaA, accepted.packSha256)
    }

    @Test
    fun sameSequenceAndSameBytesIsIdempotent() {
        val current = PackActivationState(7L, shaA)

        assertEquals(
            current,
            PackActivationPolicy.accept(current, 7L, shaA),
        )
    }

    @Test
    fun lowerSequenceIsRejectedEvenWhenPackBytesAreValid() {
        val current = PackActivationState(7L, shaA)

        assertThrows(IllegalStateException::class.java) {
            PackActivationPolicy.accept(current, 6L, shaB)
        }
    }

    @Test
    fun sameSequenceCannotBeReboundToDifferentBytes() {
        val current = PackActivationState(7L, shaA)

        assertThrows(IllegalStateException::class.java) {
            PackActivationPolicy.accept(current, 7L, shaB)
        }
    }

    @Test
    fun higherSequenceAdvancesState() {
        val next = PackActivationPolicy.accept(
            PackActivationState(7L, shaA),
            8L,
            shaB,
        )

        assertEquals(PackActivationState(8L, shaB), next)
    }

    @Test
    fun codecRoundTripIsStrictAndDeterministic() {
        val state = PackActivationState(42L, shaA)
        val encoded = PackActivationStateCodec.encode(state)

        assertEquals(state, PackActivationStateCodec.decode(encoded))
        assertArrayEquals(encoded, PackActivationStateCodec.encode(state))
    }

    @Test
    fun malformedStateFailsClosed() {
        assertThrows(IllegalStateException::class.java) {
            PackActivationStateCodec.decode(
                "aaris-pack-activation-v1\nrelease_sequence=7\n".toByteArray(),
            )
        }
    }
}