package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test

class SenderEvidenceBoundaryTest {
    private fun sender(
        reason: String = "none",
        stream: String = "screen",
        codec: String = "video/H264",
        fps: Int = 30,
        implementation: String? = "c2.qti.avc.encoder"
    ) = VideoHealthSnapshot(
        "outbound", codec, 0, 0, 0, 0, 0, 720, 1600,
        reason, 40, 0.0, streamId = stream, codecImplementation = implementation,
        recent = VideoHealthWindow(1000, fps, 5.0, null, null, null,
            sendQueueMs = 5.0)
    )

    private fun observe(
        governor: VideoCadenceGovernor,
        snapshot: VideoHealthSnapshot,
        nowMs: Long
    ) = governor.observe(snapshot, null, governor.cap, nowMs,
        producerFps = 60.0, maximumFps = 30)

    private fun receiver(fps: Int, sequence: Long) = VideoHealthWindow(
        1000, fps, 5.0, 5.0, 0, 0,
        presentationIntervalMs = 1000, presentedFrames = fps,
        maxRenderGapMs = 34, presentationAgeMs = 50,
        displayRefreshRateHz = 60.0,
        presentationSampleSequence = sequence, presentationSampleAgeMs = 50
    )

    private fun probe(
        governor: VideoCadenceGovernor,
        snapshot: VideoHealthSnapshot,
        nowMs: Long,
        sequence: Long
    ) = governor.observe(snapshot, receiver(governor.cap, sequence),
        governor.cap, nowMs, producerFps = 60.0)

    @Test fun consecutiveSameSenderPressureStillReducesCadence() {
        val governor = VideoCadenceGovernor(30, 30)
        assertFalse(observe(governor, sender(reason = "cpu"), 1000L))
        assertTrue(observe(governor, sender(reason = "cpu"), 2000L))
        assertEquals(24, governor.cap)
    }

    @Test fun replacementStreamOrCodecRequiresNewOrdinaryPressureWindows() {
        for (replacement in listOf(sender(reason = "cpu", stream = "new"),
            sender(reason = "cpu", codec = "video/VP8"))) {
            val governor = VideoCadenceGovernor(30, 30)
            assertFalse(observe(governor, sender(reason = "cpu"), 1000L))
            assertFalse(observe(governor, replacement, 2000L))
            assertEquals(30, governor.cap)
            assertTrue(observe(governor, replacement, 3000L))
            assertEquals(24, governor.cap)
        }
    }

    @Test fun concreteEncoderReplacementRequiresNewPressureWindows() {
        val governor = VideoCadenceGovernor(30, 30)
        val replacement = sender(reason = "cpu", implementation = "c2.android.avc.encoder")
        assertFalse(observe(governor, sender(reason = "cpu"), 1000L))
        assertFalse(observe(governor, replacement, 2000L))
        assertEquals(30, governor.cap)
        assertTrue(observe(governor, replacement, 3000L))
    }

    @Test fun missingOrDifferentlyFormattedComponentLabelDoesNotResetEvidence() {
        val governor = VideoCadenceGovernor(30, 30)
        assertFalse(observe(governor,
            sender(reason = "cpu", implementation = " C2.QTI.AVC.ENCODER "), 1000L))
        governor.onSenderEvidence(sender(implementation = null).copy(recent = null), 1200L)
        assertTrue(observe(governor, sender(reason = "cpu"), 2000L))
        assertEquals(24, governor.cap)
    }

    @Test fun firstKnownEncoderRequiresFreshProofAndDoesNotInheritFromAnotherStream() {
        for (start in listOf(sender(reason = "cpu", implementation = null),
            sender(reason = "cpu", stream = "old"))) {
            val governor = VideoCadenceGovernor(30, 30)
            assertFalse(observe(governor, start, 1000L))
            if (start.streamId == "old") {
                governor.onSenderEvidence(sender(implementation = null).copy(recent = null), 1200L)
                assertFalse(observe(governor, sender(reason = "cpu", implementation = null), 1500L))
            }
            assertFalse(observe(governor, sender(reason = "cpu"), 2000L))
            assertEquals(30, governor.cap)
            assertTrue(observe(governor, sender(reason = "cpu"), 3000L))
        }
    }

    @Test fun telemetryGapOrBackwardClockRequiresNewPressureWindows() {
        for (replacementAt in listOf(17001L, 9000L)) {
            val governor = VideoCadenceGovernor(30, 30)
            assertFalse(observe(governor, sender(reason = "cpu"), 10000L))
            assertFalse(observe(governor, sender(reason = "cpu"), replacementAt))
            assertEquals(30, governor.cap)
            assertTrue(observe(governor, sender(reason = "cpu"), replacementAt + 1000L))
        }
    }

    @Test fun incompleteSameSenderProbePreservesRecentVotesButCannotRefreshThem() {
        val recent = VideoCadenceGovernor(30, 30)
        val pressure = sender(reason = "cpu")
        assertFalse(observe(recent, pressure, 1000L))
        assertFalse(observe(recent, pressure.copy(recent = null), 1200L))
        assertTrue(observe(recent, pressure, 2000L))

        for (incomplete in listOf(pressure.copy(recent = null),
            pressure.copy(recent = pressure.recent!!.copy(intervalMs = 499)))) {
            val expired = VideoCadenceGovernor(30, 30)
            assertFalse(observe(expired, pressure, 1000L))
            assertFalse(observe(expired, incomplete, 5000L))
            assertFalse(observe(expired, pressure, 7500L))
            assertEquals(30, expired.cap)
        }
    }

    @Test fun replacementWithoutCompletedIntervalDiscardsOldEvidenceImmediately() {
        val governor = VideoCadenceGovernor(30, 30)
        val replacement = sender(reason = "cpu", stream = "new")
        assertFalse(observe(governor, sender(reason = "cpu"), 1000L))
        governor.onSenderEvidence(replacement.copy(recent = null), 1200L)
        assertFalse(observe(governor, replacement, 2000L))
        assertEquals(30, governor.cap)
        assertTrue(observe(governor, replacement, 3000L))
    }

    @Test fun repeatedBoundaryAdmissionDoesNotEraseSameWindowContinuity() {
        val governor = VideoCadenceGovernor(30, 30)
        val pressure = sender(reason = "cpu")
        governor.onSenderEvidence(pressure, 1000L)
        governor.onSenderEvidence(pressure, 1000L)
        assertFalse(observe(governor, pressure, 1000L))
        governor.onSenderEvidence(pressure, 2000L)
        assertTrue(observe(governor, pressure, 2000L))
    }

    @Test fun replacementOrExpiredCleanVotesCannotPromoteTheFirstNewSample() {
        for ((replacement, at) in listOf(sender(stream = "new") to 16000L,
            sender(codec = "video/VP8") to 16000L, sender() to 22001L)) {
            val governor = VideoCadenceGovernor(30, 15)
            for (second in 1..15) {
                assertFalse(observe(governor, sender(), second * 1000L))
            }
            assertFalse(observe(governor, replacement, at))
            assertEquals(15, governor.cap)
            for (window in 1..14) {
                assertFalse(observe(governor, replacement, at + window * 1000L))
            }
            assertTrue(observe(governor, replacement, at + 15000L))
            assertEquals(20, governor.cap)
        }
    }

    @Test fun clarityVotesAreFencedBeforeTheHostChoosesThatLane() {
        val governor = VideoCadenceGovernor(60, 60)
        governor.onSenderEvidence(sender(), 1000L)
        assertFalse(governor.observeClarityBandwidthCeiling(30, 60, 1000L))
        governor.onSenderEvidence(sender(stream = "new"), 2000L)
        assertFalse(governor.observeClarityBandwidthCeiling(30, 60, 2000L))
        assertEquals(60, governor.cap)
        assertTrue(governor.observeClarityBandwidthCeiling(30, 60, 3000L))
        assertEquals(30, governor.cap)
    }

    @Test fun standAloneClarityVotesExpireAcrossGapsAndClockReversal() {
        for (nextAt in listOf(9001L, 500L)) {
            val governor = VideoCadenceGovernor(60, 60)
            assertFalse(governor.observeClarityBandwidthCeiling(30, 60, 2000L))
            assertFalse(governor.observeClarityBandwidthCeiling(30, 60, nextAt))
            assertEquals(60, governor.cap)
            assertTrue(governor.observeClarityBandwidthCeiling(30, 60, nextAt + 1000L))
        }
    }

    @Test fun interactionRescueAndThirtyFpsProbeRequireFreshSenderVotes() {
        for (initial in listOf(15, 24)) {
            for ((replacement, at) in listOf(sender(stream = "new") to 2000L,
                sender() to 8001L, sender() to 500L)) {
                val governor = VideoCadenceGovernor(30, initial)
                fun sample(snapshot: VideoHealthSnapshot, time: Long) =
                    governor.tryProbeDuringInteraction(snapshot, null, 60.0, true, time)
                assertFalse(sample(sender(), 1000L))
                assertFalse(sample(replacement, at))
                assertEquals(initial, governor.cap)
                assertTrue(sample(replacement, at + 1000L))
                assertEquals(if (initial == 15) 24 else 30, governor.cap)
            }
        }
    }

    @Test fun replacementCannotConfirmAnOldFullCadencePressureVote() {
        val governor = VideoCadenceGovernor(60, 60)
        val pressure = sender(fps = 60).let {
            it.copy(recent = it.recent!!.copy(sendQueueMs = 45.0))
        }
        val receiver = VideoHealthWindow(1000, 60, 5.0, 20.0, 0, 0)
        assertFalse(governor.observe(pressure, receiver, 60, 1000L))
        val replacement = pressure.copy(streamId = "new")
        assertFalse(governor.observe(replacement, receiver, 60, 1500L))
        assertEquals(60, governor.cap)
        assertTrue(governor.observe(replacement, receiver, 60, 2000L))
        assertEquals(58, governor.cap)
    }

    @Test fun senderReplacementDiscardsFineProbeCandidateAndActiveTrialProof() {
        val governor = VideoCadenceGovernor(60, 30)
        assertFalse(probe(governor, sender(), 1000L, 1))
        assertFalse(probe(governor, sender(stream = "new"), 2000L, 2))
        assertFalse(probe(governor, sender(stream = "new"), 3000L, 3))
        assertTrue(probe(governor, sender(stream = "new"), 4000L, 4))
        assertEquals(36, governor.cap)
        assertTrue(governor.probingHighCadence)

        governor.onSenderEvidence(sender(stream = "third", fps = 36).copy(recent = null), 4200L)
        assertEquals(36, governor.cap)
        assertFalse(governor.probingHighCadence)
        assertFalse(probe(governor, sender(stream = "third", fps = 36), 4500L, 5))
        assertEquals(36, governor.cap)
    }

    @Test fun senderReplacementPreservesFailedFineTargetBackoff() {
        val governor = VideoCadenceGovernor(60, 30)
        assertFalse(probe(governor, sender(), 1000L, 1))
        assertTrue(probe(governor, sender(), 2000L, 2))
        assertTrue(probe(governor, sender(reason = "cpu", fps = 36), 3000L, 3))
        assertEquals(30, governor.cap)
        governor.onSenderEvidence(sender(stream = "new"), 3500L)
        for ((index, time) in listOf(4500L, 5500L, 6500L).withIndex()) {
            assertFalse(probe(governor, sender(stream = "new"), time, index + 4L))
            assertEquals(30, governor.cap)
        }
    }

    @Test fun severeFirstReplacementWindowStillGetsImmediateRelief() {
        val governor = VideoCadenceGovernor(30, 30)
        assertFalse(observe(governor, sender(), 1000L))
        assertTrue(observe(governor,
            sender(stream = "new").copy(packetLossRatio = 0.20), 2000L))
        assertEquals(24, governor.cap)
    }

    @Test fun replacementPreservesOverloadCooldownForFingerDown() {
        val governor = VideoCadenceGovernor(30, 30)
        assertTrue(observe(governor,
            sender(fps = 10).copy(packetLossRatio = 0.20), 1000L))
        val cap = governor.cap
        assertTrue(cap < 30)
        governor.onSenderEvidence(sender(stream = "new"), 2000L)
        assertFalse(governor.ensureInteractionFloor(30, 2000L))
        assertEquals(cap, governor.cap)
    }
}
