package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EncoderPerformancePolicyTest {
    @Test
    fun selectsHighestEstablishedCadenceWithPositiveCoverage() {
        val covered = setOf(15, 20, 24, 30, 36, 40, 45, 50)
        assertEquals(
            50,
            EncoderPerformancePolicy.highestGuaranteedFps(60) {
                it in covered
            }
        )
    }

    @Test
    fun neverInventsAnIntermediateCadence() {
        // A hypothetical component may sustain 48, but 48 is not an app
        // adaptation rung. The envelope must not change the governor topology.
        assertNull(
            EncoderPerformancePolicy.highestGuaranteedFps(60) {
                it == 48
            }
        )
    }

    @Test
    fun callerMaximumStillBoundsTheGuarantee() {
        assertEquals(
            30,
            EncoderPerformancePolicy.highestGuaranteedFps(30) {
                it >= 30
            }
        )
    }

    @Test
    fun missingGuaranteePreservesExistingDeviceLimit() {
        assertEquals(
            60,
            EncoderPerformancePolicy.effectiveLimit(
                deviceLimitFps = 60,
                guaranteedCodecFps = null
            )
        )
    }

    @Test
    fun positiveCodecGuaranteeCanOnlyLowerTheLimit() {
        assertEquals(
            30,
            EncoderPerformancePolicy.effectiveLimit(
                deviceLimitFps = 60,
                guaranteedCodecFps = 30
            )
        )
        assertEquals(
            24,
            EncoderPerformancePolicy.effectiveLimit(
                deviceLimitFps = 24,
                guaranteedCodecFps = 60
            )
        )
    }
}
