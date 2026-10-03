package com.aaris.remoteassist.ai

import org.junit.Assert.*
import org.junit.Test

class AiScreenLedgerTest {
    @Test fun eventsDoNotRevokeTicketButExpiryConsumptionAndDisconnectDo() {
        val ledger = AiScreenLedger()
        ledger.issue("first", 100)
        val version = ledger.version
        repeat(100) { ledger.changed(101L + it) }
        assertTrue(ledger.valid("first", version, 40_000))
        assertFalse(ledger.valid("first", version + 1, 40_000))
        assertFalse(ledger.valid("first", version, 90_101))
        assertFalse(ledger.valid("first", version, 99))
        ledger.consume()
        assertFalse(ledger.valid("first", version, 202))
        ledger.issue("second", 203)
        val second = ledger.version
        ledger.invalidate(204)
        assertFalse(ledger.valid("second", second, 205))
    }
    @Test fun newObservationRevokesPriorTicketEvenOnUnchangedScreen() {
        val ledger = AiScreenLedger()
        ledger.issue("a", 1); val old = ledger.version
        ledger.issue("b", 2)
        assertFalse(ledger.valid("a", old, 3))
        assertTrue(ledger.valid("b", ledger.version, 3))
    }
    @Test fun regionCheckIgnoresUnrelatedAnimationButDetectsTargetAndColorChanges() {
        val a = ByteArray(AiVisualFingerprint.WIDTH * AiVisualFingerprint.HEIGHT * 3) { 40 }
        val scope = AiActionScope(0.8, 0.8)
        val other = a.clone().apply { for (i in 0 until size / 2) this[i] = 120 }
        assertFalse(AiVisualFingerprint.materiallyDifferent(a, other, scope))
        val changed = a.clone().apply { for (i in indices step 3) this[i + 1] = 120 }
        assertTrue(AiVisualFingerprint.materiallyDifferent(a, changed, scope))
        assertTrue(AiVisualFingerprint.materiallyDifferent(a, byteArrayOf(), scope))
    }
    @Test fun rotationMapsSourceCornerToUprightTarget() {
        val width = 80; val height = 160
        val base = ByteArray(width * height * 3 / 2) { 40 }
        val changed = base.clone().apply { for (y in 0 until 40) for (x in 0 until 20) this[y * width + x] = 120 }
        for ((rotation, point) in listOf(0 to (0.1 to 0.1), 90 to (0.9 to 0.1), 180 to (0.9 to 0.9), 270 to (0.1 to 0.9))) {
            val a = AiVisualFingerprint.sample(base, width, height, rotation)
            val b = AiVisualFingerprint.sample(changed, width, height, rotation)
            assertTrue("rotation=$rotation", AiVisualFingerprint.materiallyDifferent(a, b, AiActionScope(point.first, point.second)))
            assertFalse(AiVisualFingerprint.materiallyDifferent(a, b, AiActionScope(0.5, 0.5)))
        }
    }
}
