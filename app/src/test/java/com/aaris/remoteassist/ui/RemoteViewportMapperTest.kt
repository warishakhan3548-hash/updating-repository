package com.aaris.remoteassist.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

class RemoteViewportMapperTest {
    @Test
    fun centerMapsToCenterWithSideBars() {
        val point = RemoteViewportMapper.normalize(
            touchX = 500f,
            touchY = 1000f,
            viewWidth = 1000f,
            viewHeight = 2000f,
            remoteWidth = 1080,
            remoteHeight = 2400
        )

        assertNotNull(point)
        assertEquals(0.5f, point!!.x, 0.0001f)
        assertEquals(0.5f, point.y, 0.0001f)
    }

    @Test
    fun ignoresTouchInsideBlackBar() {
        val point = RemoteViewportMapper.normalize(
            touchX = 20f,
            touchY = 1000f,
            viewWidth = 1000f,
            viewHeight = 2000f,
            remoteWidth = 1080,
            remoteHeight = 2400
        )

        assertNull(point)
    }

    @Test
    fun mapsLandscapeRemoteInsideTallController() {
        val point = RemoteViewportMapper.normalize(
            touchX = 500f,
            touchY = 1000f,
            viewWidth = 1000f,
            viewHeight = 2000f,
            remoteWidth = 2400,
            remoteHeight = 1080
        )

        assertNotNull(point)
        assertEquals(0.5f, point!!.x, 0.0001f)
        assertEquals(0.5f, point.y, 0.0001f)
    }

    @Test
    fun rejectsInvalidGeometry() {
        assertNull(
            RemoteViewportMapper.normalize(
                touchX = 1f,
                touchY = 1f,
                viewWidth = 0f,
                viewHeight = 100f,
                remoteWidth = 1080,
                remoteHeight = 2400
            )
        )
    }
}
