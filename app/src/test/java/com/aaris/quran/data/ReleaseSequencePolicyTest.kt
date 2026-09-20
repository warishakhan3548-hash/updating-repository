package com.aaris.quran.data

import org.junit.Assert.assertThrows
import org.junit.Test

class ReleaseSequencePolicyTest {
    @Test
    fun acceptsFirstSameNewerAndMaximumReleaseSequences() {
        ReleaseSequencePolicy.requireAcceptable(highestAccepted = 0L, candidate = 1L)
        ReleaseSequencePolicy.requireAcceptable(highestAccepted = 7L, candidate = 7L)
        ReleaseSequencePolicy.requireAcceptable(highestAccepted = 7L, candidate = 8L)
        ReleaseSequencePolicy.requireAcceptable(
            highestAccepted = ReleaseSequencePolicy.MAX_SIGNED_SEQUENCE - 1,
            candidate = ReleaseSequencePolicy.MAX_SIGNED_SEQUENCE,
        )
    }

    @Test
    fun rejectsReleaseRollback() {
        assertThrows(IllegalStateException::class.java) {
            ReleaseSequencePolicy.requireAcceptable(
                highestAccepted = 9L,
                candidate = 8L,
            )
        }
    }

    @Test
    fun rejectsInvalidOrOutOfProtocolSequenceState() {
        assertThrows(IllegalArgumentException::class.java) {
            ReleaseSequencePolicy.requireAcceptable(
                highestAccepted = -1L,
                candidate = 1L,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            ReleaseSequencePolicy.requireAcceptable(
                highestAccepted = 0L,
                candidate = 0L,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            ReleaseSequencePolicy.requireAcceptable(
                highestAccepted = 0L,
                candidate = ReleaseSequencePolicy.MAX_SIGNED_SEQUENCE + 1,
            )
        }
    }
}
