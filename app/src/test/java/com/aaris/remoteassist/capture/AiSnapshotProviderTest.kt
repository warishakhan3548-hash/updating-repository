package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Test

class AiSnapshotProviderTest {
    @Test
    fun portraitFrameScalesToRequestedLongEdge() {
        assertEquals(
            576 to 1280,
            aiSnapshotDimensions(
                width = 1080,
                height = 2400,
                maxLongSidePx = 1280
            )
        )
    }

    @Test
    fun landscapeFrameKeepsAspectAndEvenDimensions() {
        assertEquals(
            1280 to 576,
            aiSnapshotDimensions(
                width = 2400,
                height = 1080,
                maxLongSidePx = 1280
            )
        )
    }

    @Test
    fun alreadySmallFrameIsNotUpscaled() {
        assertEquals(
            720 to 1280,
            aiSnapshotDimensions(
                width = 720,
                height = 1280,
                maxLongSidePx = 2400
            )
        )
    }

    @Test
    fun oddScaledValuesAreRoundedDownToEvenYuvDimensions() {
        assertEquals(
            424 to 960,
            aiSnapshotDimensions(
                width = 1001,
                height = 2261,
                maxLongSidePx = 960
            )
        )
    }
}
