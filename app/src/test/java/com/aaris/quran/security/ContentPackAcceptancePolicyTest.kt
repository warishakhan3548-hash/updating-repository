package com.aaris.quran.security

import org.junit.Assert.assertEquals
import org.junit.Test

class ContentPackAcceptancePolicyTest {
    private val manifestA = "a".repeat(64)
    private val manifestB = "b".repeat(64)
    private val contentA = "c".repeat(64)
    private val contentB = "d".repeat(64)

    @Test
    fun acceptsFirstRelease() {
        assertEquals(
            ContentPackAcceptanceDecision.ACCEPT_FIRST,
            evaluateContentPackAcceptance(null, record(4, manifestA, contentA)),
        )
    }

    @Test
    fun acceptsIdenticalReleaseIdempotently() {
        val accepted = record(4, manifestA, contentA)
        assertEquals(
            ContentPackAcceptanceDecision.ACCEPT_IDENTICAL,
            evaluateContentPackAcceptance(accepted, accepted),
        )
    }

    @Test
    fun acceptsHigherSignedSequence() {
        assertEquals(
            ContentPackAcceptanceDecision.ACCEPT_ADVANCE,
            evaluateContentPackAcceptance(
                record(4, manifestA, contentA),
                record(5, manifestB, contentB),
            ),
        )
    }

    @Test
    fun rejectsLowerSequenceEvenWhenBytesAreValid() {
        assertEquals(
            ContentPackAcceptanceDecision.REJECT_ROLLBACK,
            evaluateContentPackAcceptance(
                record(5, manifestB, contentB),
                record(4, manifestA, contentA),
            ),
        )
    }

    @Test
    fun rejectsDifferentManifestAtSameSequence() {
        assertEquals(
            ContentPackAcceptanceDecision.REJECT_EQUIVOCATION,
            evaluateContentPackAcceptance(
                record(5, manifestA, contentA),
                record(5, manifestB, contentA),
            ),
        )
    }

    @Test
    fun rejectsDifferentContentAtSameSequence() {
        assertEquals(
            ContentPackAcceptanceDecision.REJECT_EQUIVOCATION,
            evaluateContentPackAcceptance(
                record(5, manifestA, contentA),
                record(5, manifestA, contentB),
            ),
        )
    }

    private fun record(
        sequence: Long,
        manifestSha256: String,
        contentSha256: String,
    ) = ContentPackAcceptanceRecord(
        releaseSequence = sequence,
        manifestSha256 = manifestSha256,
        contentSha256 = contentSha256,
    )
}
