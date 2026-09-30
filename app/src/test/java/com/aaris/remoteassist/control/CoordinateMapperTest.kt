package com.aaris.remoteassist.control

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CoordinateMapperTest {
    @Test fun mapsRenderedCenterToRemoteCenter() {
        val point = CoordinateMapper.map(
            controllerX = 500f,
            controllerY = 1000f,
            renderedRemoteRect = FloatRect(100f, 200f, 900f, 1800f),
            remote = RemoteDisplay(1080, 2400, 7)
        )!!
        assertEquals(0.5f, point.nx, 0.0001f)
        assertEquals(0.5f, point.ny, 0.0001f)
        assertEquals(7, point.generation)
    }

    @Test fun ignoresTouchesInLetterboxBars() {
        assertNull(
            CoordinateMapper.map(
                controllerX = 20f,
                controllerY = 500f,
                renderedRemoteRect = FloatRect(100f, 0f, 900f, 1600f),
                remote = RemoteDisplay(1080, 2400, 1)
            )
        )
    }
}
