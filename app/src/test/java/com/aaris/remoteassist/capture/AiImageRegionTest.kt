package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AiImageRegionTest {
    @Test
    fun zoomRequestsSharperSourceWithoutExceedingExistingCaptureCap() {
        val quarterScreen =
            AiImageRegion(
                left = 0.25,
                top = 0.25,
                right = 0.50,
                bottom = 0.50
            )

        assertEquals(
            2400,
            quarterScreen.requiredSourceLongEdge(
                deliveryLongEdgePx = 960,
                analysisLongEdgePx = 1280,
                sourceLongEdgeCapPx = 2400
            )
        )

        val wideRegion =
            AiImageRegion(
                left = 0.10,
                top = 0.20,
                right = 0.90,
                bottom = 0.80
            )
        assertEquals(
            1280,
            wideRegion.requiredSourceLongEdge(
                deliveryLongEdgePx = 960,
                analysisLongEdgePx = 1280,
                sourceLongEdgeCapPx = 2400
            )
        )
    }

    @Test
    fun tinyOrInvertedRegionsFailClosed() {
        assertThrows(IllegalArgumentException::class.java) {
            AiImageRegion(
                left = 0.50,
                top = 0.20,
                right = 0.40,
                bottom = 0.80
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            AiImageRegion(
                left = 0.10,
                top = 0.10,
                right = 0.13,
                bottom = 0.90
            )
        }
    }
}
