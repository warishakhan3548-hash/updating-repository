package com.aaris.remoteassist.webrtc.advanced

import com.aaris.remoteassist.capture.StalenessShadowSnapshot
import org.junit.Assert.assertEquals
import org.junit.Test

class StalenessShadowSnapshotTest {
    @Test
    fun dropRatioIsBoundedAndDeterministic() {
        assertEquals(
            0.25,
            StalenessShadowSnapshot(100, 25, 80.0, 140.0).wouldDropRatio,
            0.0001
        )
        assertEquals(
            0.0,
            StalenessShadowSnapshot(0, 0, null, null).wouldDropRatio,
            0.0001
        )
    }
}
