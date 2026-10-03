package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameDeltaAnalyzerTest {
    @Test
    fun identicalFramesProduceNoNetworkRegions() {
        val width = 384
        val height = 768
        val frame = patterned(width, height)

        val plan = FrameDeltaAnalyzer.analyze(
            previousY = frame,
            currentY = frame.copyOf(),
            width = width,
            height = height
        )

        assertEquals(0, plan.shiftY)
        assertTrue(plan.regions.isEmpty())
        assertEquals(0.0, plan.changedFraction, 0.0001)
        assertFalse(plan.forceKeyframe)
    }

    @Test
    fun smallLocalChangeBecomesPatchInsteadOfKeyframe() {
        val width = 384
        val height = 768
        val previous = patterned(width, height)
        val current = previous.copyOf()

        for (y in 220 until 300) {
            for (x in 100 until 180) {
                current[y * width + x] = 240.toByte()
            }
        }

        val plan = FrameDeltaAnalyzer.analyze(
            previous,
            current,
            width,
            height
        )

        assertFalse(plan.forceKeyframe)
        assertTrue(plan.regions.isNotEmpty())
        assertTrue(plan.changedFraction < 0.25)
    }

    @Test
    fun broadPageReplacementFallsBackToKeyframe() {
        val width = 384
        val height = 768
        val previous = ByteArray(width * height) { 20 }
        val current = ByteArray(width * height) { 220.toByte() }

        val plan = FrameDeltaAnalyzer.analyze(
            previous,
            current,
            width,
            height
        )

        assertTrue(plan.forceKeyframe)
    }

    @Test
    fun strongVerticalScrollUsesShiftAndSmallExposedPatch() {
        val width = 384
        val height = 768
        val previous = patterned(width, height)
        val scroll = 96
        val current = ByteArray(width * height)

        // Content moves upward by 96px: current(y) = previous(y + 96).
        for (y in 0 until height - scroll) {
            previous.copyInto(
                destination = current,
                destinationOffset = y * width,
                startIndex = (y + scroll) * width,
                endIndex = (y + scroll + 1) * width
            )
        }
        for (y in height - scroll until height) {
            for (x in 0 until width) {
                current[y * width + x] =
                    ((x * 13 + y * 7 + 91) and 0xff).toByte()
            }
        }

        val plan = FrameDeltaAnalyzer.analyze(
            previous,
            current,
            width,
            height
        )

        assertEquals(-scroll, plan.shiftY)
        assertFalse(plan.forceKeyframe)
        assertTrue(plan.changedFraction < 0.30)
        assertTrue(plan.regions.any { region ->
            region.y + region.height >= height - 96
        })
    }

    private fun patterned(width: Int, height: Int): ByteArray =
        ByteArray(width * height) { index ->
            val x = index % width
            val y = index / width
            var value =
                (x * 73_856_093) xor
                    (y * 19_349_663) xor
                    ((x + y) * 83_492_791)
            value = value xor (value ushr 13)
            (value and 0xff).toByte()
        }
}
