package com.aaris.remoteassist.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteGestureTimingTest {
    @Test
    fun shortTapKeepsActualEventDuration() {
        assertEquals(
            120,
            RemoteGestureTiming.durationMs(
                startEventTimeMs = 10_000L,
                endEventTimeMs = 10_120L,
                minMs = 1,
                maxMs = 2_500
            )
        )
    }

    @Test
    fun sub300msTapNeverBecomesLongPressBecauseOfClockOffset() {
        assertEquals(
            240,
            RemoteGestureTiming.durationMs(
                startEventTimeMs = 4_000_000L,
                endEventTimeMs = 4_000_240L,
                minMs = 1,
                maxMs = 2_500
            )
        )
    }

    @Test
    fun longPressKeepsRealHoldDuration() {
        assertEquals(
            700,
            RemoteGestureTiming.durationMs(
                startEventTimeMs = 1_000L,
                endEventTimeMs = 1_700L,
                minMs = 1,
                maxMs = 2_500
            )
        )
    }

    @Test
    fun multiTouchUsesSameEventClockAndBounds() {
        assertEquals(
            80,
            RemoteGestureTiming.durationMs(
                startEventTimeMs = 3_000L,
                endEventTimeMs = 3_030L,
                minMs = 80,
                maxMs = 2_500
            )
        )
        assertEquals(
            2_500,
            RemoteGestureTiming.durationMs(
                startEventTimeMs = 3_000L,
                endEventTimeMs = 9_000L,
                minMs = 80,
                maxMs = 2_500
            )
        )
    }

    @Test
    fun outOfOrderEventIsFailSafeNotHugeDuration() {
        assertEquals(
            1,
            RemoteGestureTiming.durationMs(
                startEventTimeMs = 5_000L,
                endEventTimeMs = 4_900L,
                minMs = 1,
                maxMs = 2_500
            )
        )
    }
}
