package com.aaris.remoteassist.ai

import org.junit.Assert.*
import org.junit.Test

class AiScreenLedgerTest {
    @Test fun screenChangeExpiryAndConsumptionRejectOldDecisions() {
        val ledger = AiScreenLedger()
        ledger.issue("first", 100)
        assertTrue(ledger.valid("first", 0, 200))
        ledger.changed(201)
        assertFalse(ledger.valid("first", 0, 202))
        ledger.issue("second", 203)
        assertTrue(ledger.valid("second", 1, 204))
        ledger.consume()
        assertFalse(ledger.valid("second", 1, 205))
        ledger.issue("third", 300)
        assertFalse(ledger.valid("third", 1, 30_301))
        assertFalse(ledger.valid("third", 1, 299))
    }
    @Test fun newObservationInvalidatesPriorTicketEvenOnUnchangedScreen() {
        val ledger = AiScreenLedger()
        ledger.issue("a", 1); ledger.issue("b", 2)
        assertFalse(ledger.valid("a", 0, 3)); assertTrue(ledger.valid("b", 0, 3))
        ledger.invalidate(4); assertFalse(ledger.valid("b", 0, 5))
    }
    @Test fun visualChangeDetectionToleratesCaretButRejectsMovedContent() {
        val a = ByteArray(3840) { 40 }
        assertFalse(AiVisualFingerprint.materiallyDifferent(a, a.clone().apply { this[100] = 120 }))
        assertTrue(AiVisualFingerprint.materiallyDifferent(a, a.clone().apply { for (i in 0..80) this[i] = 120 }))
        assertTrue(AiVisualFingerprint.materiallyDifferent(a, byteArrayOf()))
    }
}
