package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Test

class RealtimeCaptureOutputFormatTest {
    @Test
    fun dynamicMotionKeepsCurrentDimensionsButAdmitsCadenceChange() {
        val current = Triple(1080, 2400, 30)
        val requested = Triple(360, 800, 60)

        val next =
            resolveRealtimeCaptureOutputFormat(
                current = current,
                requested = requested,
                deferResize = true
            )

        assertEquals(1080, next.first)
        assertEquals(2400, next.second)
        assertEquals(60, next.third)
    }

    @Test
    fun settledMotionCommitsLatestMeasuredPixelEnvelope() {
        val current = Triple(1080, 2400, 60)
        val requested = Triple(360, 800, 30)

        val next =
            resolveRealtimeCaptureOutputFormat(
                current = current,
                requested = requested,
                deferResize = false
            )

        assertEquals(requested, next)
    }

    @Test
    fun physicalDisplayGeometryChangeBypassesMotionResizeGuard() {
        val current = Triple(1080, 2400, 60)
        val rotated = Triple(2400, 1080, 60)

        val next =
            resolveRealtimeCaptureOutputFormat(
                current = current,
                requested = rotated,
                deferResize = true,
                forceResize = true
            )

        assertEquals(rotated, next)
    }

    @Test
    fun startupUsesRequestedEnvelopeWhenThereIsNoPreviousFormat() {
        val requested = Triple(1080, 2400, 30)

        val next =
            resolveRealtimeCaptureOutputFormat(
                current = null,
                requested = requested,
                deferResize = true
            )

        assertEquals(requested, next)
    }
}
