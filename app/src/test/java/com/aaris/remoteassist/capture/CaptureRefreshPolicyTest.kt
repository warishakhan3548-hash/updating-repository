package com.aaris.remoteassist.capture

import org.junit.Assert.*
import org.junit.Test

class CaptureRefreshPolicyTest {
    @Test fun idleRefreshRequiresARealTextureAndIsRateLimitedEvenIfProducerIsStuck() {
        val policy = CaptureRefreshPolicy()
        assertFalse(policy.shouldRefresh(10_000))
        policy.onSample(10_000)
        assertFalse(policy.shouldRefresh(10_999))
        assertTrue(policy.shouldRefresh(11_000))
        assertFalse(policy.shouldRefresh(11_001))
        assertFalse(policy.shouldRefresh(11_999))
        assertTrue(policy.shouldRefresh(12_000))
    }

    @Test fun appliedInteractionPullsAfterOneTickOnlyWhenNaturalProducerStayedStale() {
        val policy = CaptureRefreshPolicy()
        policy.onSample(1_000)

        policy.onInteractionApplied(1_010)
        assertFalse(policy.shouldRefreshForInteraction(1_015))
        assertTrue(policy.shouldRefreshForInteraction(1_016))
        assertFalse(policy.shouldRefreshForInteraction(1_017))

        // Even a frame in the same millisecond is distinguishable by
        // capture generation and cancels the pull deterministically.
        policy.onInteractionApplied(2_000)
        policy.onSample(2_000)
        assertFalse(policy.shouldRefreshForInteraction(2_020))
    }

    @Test fun oldTextureHeartbeatCannotCancelAnUnrenderedPostTouchRefresh() {
        val policy = CaptureRefreshPolicy()
        policy.onSample(1_000, textureTimestampNs = 123_000L)
        policy.onInteractionApplied(1_010)

        // An idle/compatibility forceFrame callback arrived after input, but
        // reused the same compositor texture; the touch is still unobserved.
        policy.onSample(1_012, textureTimestampNs = 123_000L)
        assertFalse(policy.shouldRefreshForInteraction(1_015))
        assertTrue(policy.shouldRefreshForInteraction(1_016))
        assertFalse(policy.shouldRefreshForInteraction(1_017))
    }

    @Test fun genuinelyNewTextureCancelsAnUnnecessaryPostTouchRefresh() {
        val policy = CaptureRefreshPolicy()
        policy.onSample(2_000, textureTimestampNs = 123_000L)
        policy.onInteractionApplied(2_010)

        // Native capture produced a new texture even though the scheduler
        // timestamps could have the same millisecond resolution.
        policy.onSample(2_010, textureTimestampNs = 123_001L)
        assertFalse(policy.shouldRefreshForInteraction(2_020))
    }

    @Test fun rapidInteractionsKeepFirstDeadlineAndNeverBuildSyntheticRefreshBacklog() {
        val policy = CaptureRefreshPolicy()
        policy.onSample(10_000)

        policy.onInteractionApplied(10_010)
        policy.onInteractionApplied(10_014)
        policy.onInteractionApplied(10_018)

        // Later CONTINUE samples must not postpone the first display-tick pull.
        assertFalse(policy.shouldRefreshForInteraction(10_015))
        assertTrue(policy.shouldRefreshForInteraction(10_016))
        assertFalse(policy.shouldRefreshForInteraction(10_017))

        // Once the single-flight request is consumed, a later interaction may
        // arm the next bounded pull without inheriting stale backlog.
        policy.onInteractionApplied(10_020)
        assertFalse(policy.shouldRefreshForInteraction(10_025))
        assertTrue(policy.shouldRefreshForInteraction(10_026))
        assertFalse(policy.shouldRefreshForInteraction(10_027))
    }

    @Test fun periodicIdlePullBetweenTouchAndDisplayTickCannotSwallowTouchRefresh() {
        val policy = CaptureRefreshPolicy()
        policy.onSample(1_000, textureTimestampNs = 100L)
        policy.onInteractionApplied(1_998)

        // An independent 1 Hz idle timer wins the scheduling race. Its forced
        // sample can still reflect pixels from BEFORE the applied gesture.
        assertTrue(policy.shouldRefresh(2_000))
        policy.onSample(2_001, textureTimestampNs = 100L)

        assertFalse(policy.shouldRefreshForInteraction(2_003))
        assertTrue(policy.shouldRefreshForInteraction(2_015))
        assertFalse(policy.shouldRefreshForInteraction(2_016))

        // The interaction pull still rate-limits the normal idle timer.
        assertFalse(policy.shouldRefresh(2_500))
        assertTrue(policy.shouldRefresh(3_015))
    }

    @Test fun sameMillisecondIdleHeartbeatCannotCountAsInteractionProbe() {
        val policy = CaptureRefreshPolicy()
        policy.onSample(1_000, textureTimestampNs = 100L)

        assertTrue(policy.shouldRefresh(2_000))
        policy.onInteractionApplied(2_000)
        policy.onSample(2_001, textureTimestampNs = 100L)

        assertTrue(policy.shouldRefreshForInteraction(2_017))
        assertFalse(policy.shouldRefreshForInteraction(2_018))

        // A second gesture in the same millisecond must not multiply pulls.
        policy.onInteractionApplied(2_017)
        assertFalse(policy.shouldRefreshForInteraction(2_025))
        // A genuinely later gesture retains the existing one-probe budget.
        policy.onInteractionApplied(2_026)
        assertTrue(policy.shouldRefreshForInteraction(2_043))
    }

    @Test fun movingScreenGetsNoDuplicateWorkAndLatestSampleDefersIdleProbe() {
        val policy = CaptureRefreshPolicy()
        for (time in 0L..10_000L step 33L) {
            policy.onSample(time)
            assertFalse(policy.shouldRefresh(time + 1))
        }
        policy.onSample(10_000)
        assertFalse(policy.shouldRefresh(10_999))
        assertTrue(policy.shouldRefresh(11_000))
        policy.onSample(11_100)
        assertFalse(policy.shouldRefresh(12_000))
        assertTrue(policy.shouldRefresh(12_100))
    }

    @Test fun staticHeartbeatDoesNotPretendThatSourcePixelsAreMoving() {
        val refresh = CaptureRefreshPolicy()
        val activity = CaptureActivityTracker()
        val clock = CaptureSampleClock()
        val textureTimestamp = 1_000_000_000L
        activity.sampleFps(1_000)
        repeat(5) { index ->
            val now = 1_000L + index * 1_000L
            refresh.onSample(now)
            assertFalse(activity.onFrame(textureTimestamp))
            assertTrue(clock.timestamp(textureTimestamp, now * 1_000_000L) >= textureTimestamp)
            assertTrue(refresh.shouldRefresh(now + 1_000))
        }
        assertEquals(0.2, activity.sampleFps(6_000)!!, 0.001)
    }

    @Test fun displayTickTimingTracksRefreshRateWithoutPathologicallySmallDelays() {
        assertEquals(17L, InteractionRefreshTiming.oneDisplayTickMs(60f))
        assertEquals(12L, InteractionRefreshTiming.oneDisplayTickMs(90f))
        assertEquals(9L, InteractionRefreshTiming.oneDisplayTickMs(120f))
        assertEquals(8L, InteractionRefreshTiming.oneDisplayTickMs(144f))
        assertEquals(17L, InteractionRefreshTiming.oneDisplayTickMs(null))
        assertEquals(17L, InteractionRefreshTiming.oneDisplayTickMs(Float.NaN))
    }
}
