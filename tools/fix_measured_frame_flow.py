#!/usr/bin/env python3
"""Apply the audited Aaris Remote frame-flow corrections to original source.
Baseline: main 8222234f (1.9.61). Requires Python 3.9+ and git.
Run with --check first. Unknown source is rejected before any file is changed.
"""
import argparse
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

PATCHES = [{'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/HighCadenceProbe.kt',
  'before': '5f0a77a6c632763df3df04f826f2b811837804cd87c2b3efdb49d514f05c229f',
  'after': 'a6389ced226e7f1e9827c2c22fbb75fd26ef408bb48962866c7caa04bc22ad02',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/HighCadenceProbe.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/HighCadenceProbe.kt\n'
           'index 75d700bb..3ca67e34 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/HighCadenceProbe.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/HighCadenceProbe.kt\n'
           '@@ -136,7 +136,7 @@ internal class HighCadenceProbe {\n'
           '             freshProof &&\n'
           '                 sender != null &&\n'
           '                 sender.intervalMs in 500..6000 &&\n'
           '-                sender.fps >= currentFps * MIN_SENDER_DELIVERY_RATIO &&\n'
           '+                sender.deliveryFps >= currentFps * MIN_SENDER_DELIVERY_RATIO &&\n'
           '                 receiver!!.fps >= currentFps * MIN_DECODER_DELIVERY_RATIO &&\n'
           '                 presented!! >= currentFps * MIN_PRESENTATION_DELIVERY_RATIO &&\n'
           '                 receiver.maxRenderGapMs?.let {\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt',
  'before': '516f3347ab95292093bfd8466de9de18d10860434d1f36be8961067a4e14bea5',
  'after': 'c03a31d35f544cc7c524e0c4b2e7e8b5883fa1cb698a74fffd15d45c2ff63dfd',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt\n'
           'index f4c4b772..ee9713be 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt\n'
           '@@ -1249,8 +1249,10 @@ class HostWebRtcSession(\n'
           '                     append(fps(sourceFps))\n'
           '                     append(" target=")\n'
           '                     append(effective.fps)\n'
           '-                    append("fps send=")\n'
           '+                    append("fps encode=")\n'
           '                     append(fps(qdSender?.fps))\n'
           '+                    append(" send=")\n'
           '+                    append(fps(qdSender?.sentFps))\n'
           '                     append(" decode=")\n'
           '                     append(fps(receiver?.fps))\n'
           '                     append(" present=")\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt',
  'before': '7549ffb437230109b1b0079bec96237311e94afe0371381f5bcc02ace83f6539',
  'after': '74d61f399d010722bef166d8a68f3bb642952a99b953bab25a68696faba227e4',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
           'index af0a354d..a2b20e9c 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
           '@@ -182,8 +182,8 @@ internal class MotionVideoBudget {\n'
           '         val encodePressure = sender.frames >= 2 && underDelivery && (encodeMs ?: 0.0) > '
           'frameMs * 0.85\n'
           '         val queuePressure = (queueMs ?: 0.0) >= 80.0 || (jitterMs ?: 0.0) >= 100.0\n'
           '         val decodePressure = received != null && (decodeMs ?: 0.0) > frameMs * 0.85 &&\n'
           '-            received.fps < minOf(sender.fps, goal.toDouble()) * 0.85\n'
           '-        val expectedPresentation = minOf(goal.toDouble(), sender.fps, received?.fps ?: '
           '0.0)\n'
           '+            received.fps < minOf(sender.deliveryFps, goal.toDouble()) * 0.85\n'
           '+        val expectedPresentation = minOf(goal.toDouble(), sender.deliveryFps, '
           'received?.fps ?: 0.0)\n'
           '         // Held EGL cadence bridges independently phased stats clocks. It may\n'
           '         // block recovery, but must not become another resolution-pressure vote.\n'
           '         val presentationPressure = received?.presentationSampleFresh != false &&\n'
           '@@ -264,10 +264,10 @@ internal class MotionVideoBudget {\n'
           '             )\n'
           '         val senderLagsMotion =\n'
           '             if (interactionActive) {\n'
           '-                sender.fps < goal * INTERACTION_DELIVERY_RATIO\n'
           '+                sender.deliveryFps < goal * INTERACTION_DELIVERY_RATIO\n'
           '             } else {\n'
           '                 measuredSourceFps?.let {\n'
           '-                    sender.fps < minOf(goal.toDouble(), it) * PASSIVE_DELIVERY_RATIO\n'
           '+                    sender.deliveryFps < minOf(goal.toDouble(), it) * '
           'PASSIVE_DELIVERY_RATIO\n'
           '                 } == true\n'
           '             }\n'
           '         val bandwidthLimited =\n'
           '@@ -283,8 +283,16 @@ internal class MotionVideoBudget {\n'
           '          */\n'
           '         val bandwidthEstimateBps =\n'
           '             outbound.availableOutgoingBitrateBps.valid()\n'
           '+        // Requested FPS is a ceiling, not offered traffic. A regular 10/15 Hz\n'
           '+        // animation on a 60 Hz ceiling must not pay the 60 Hz bandwidth model.\n'
           '+        // Keep actuator/recovery budgets at the requested ceiling; discount only\n'
           '+        // predictive demand when the original producer cadence is measured.\n'
           '+        val offeredFps = minOf(\n'
           '+            goal.toDouble(),\n'
           '+            measuredSourceFps ?: goal.toDouble()\n'
           '+        ).coerceAtLeast(1.0)\n'
           '         val currentRungBitrateBps =\n'
           '-            nominalMotionBitrateBps(shortEdge, goal)\n'
           '+            nominalMotionBitrateBps(shortEdge, goal) * offeredFps / goal\n'
           '         val bandwidthHeadroomRatio =\n'
           '             bandwidthEstimateBps?.let { estimate ->\n'
           '                 estimate / currentRungBitrateBps\n'
           '@@ -333,7 +341,7 @@ internal class MotionVideoBudget {\n'
           '         val producerOutrunsSender =\n'
           '             measuredSourceFps?.let { supply ->\n'
           '                 supply >= MIN_MOVING_SOURCE_FPS &&\n'
           '-                    sender.fps < minOf(goal.toDouble(), supply) *\n'
           '+                    sender.deliveryFps < minOf(goal.toDouble(), supply) *\n'
           '                         PASSIVE_DELIVERY_RATIO\n'
           '             } == true\n'
           '         val transportProvesCongestion =\n'
           '@@ -347,13 +355,13 @@ internal class MotionVideoBudget {\n'
           '             bandwidthUnderDelivery &&\n'
           '                 (\n'
           '                     (queueMs ?: 0.0) >= NETWORK_QUEUE_PRESSURE_MS ||\n'
           '-                        sender.fps < goal * 0.60\n'
           '+                        sender.deliveryFps < goal * 0.60\n'
           '                 )\n'
           '         val severeBandwidthFreshnessPressure =\n'
           '             bandwidthUnderDelivery &&\n'
           '                 (\n'
           '                     (queueMs ?: 0.0) >= SEVERE_NETWORK_QUEUE_MS ||\n'
           '-                        sender.fps < goal * 0.45\n'
           '+                        sender.deliveryFps < goal * 0.45\n'
           '                 )\n'
           '         if (bandwidthFreshnessPressure || predictiveBandwidthPressure) {\n'
           '             lastBandwidthPressureAtMs = nowMs\n'
           '@@ -474,7 +482,7 @@ internal class MotionVideoBudget {\n'
           '                         BWE_RECOVERY_HEADROOM_RATIO\n'
           '                 } ?: true\n'
           '             val healthy =\n'
           '-                sender.fps >= goal * 0.9 &&\n'
           '+                sender.deliveryFps >= goal * 0.9 &&\n'
           '                     encodeMs != null &&\n'
           '                     encodeMs < frameMs * 0.5 &&\n'
           '                     queueMs != null &&\n'
           '@@ -486,7 +494,7 @@ internal class MotionVideoBudget {\n'
           '             // relief stays enabled, but do not also enlarge trial frames.\n'
           '             healthySamples = if (healthy && allowResolutionRecovery) healthySamples + 1 '
           'else 0\n'
           '             if (healthySamples >= 12 && nowMs - changedAtMs >= 12_000L && shortEdge < 720) '
           '{\n'
           '-                shortEdge = when { shortEdge < 360 -> 360; shortEdge < 540 -> 540; else -> '
           '720 }\n'
           '+                shortEdge = nextRecoveryRung\n'
           '                 changedAtMs = nowMs\n'
           '                 healthySamples = 0\n'
           '                 resetResidenceGrowth()\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt',
  'before': '44a24f9314f32ef63b9e04b01af5884172d627a165beb658cf10e43ac52c43fb',
  'after': '5bca855475f8389ebf621ffde76827148d06cb2de7f5c34b0de00abdf0d72b7e',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt\n'
           'index 4d0e31f1..dd04c567 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt\n'
           '@@ -89,7 +89,7 @@ internal class PhotonFreshnessGovernor {\n'
           '         lastObserveAtMs = nowMs\n'
           ' \n'
           '         val sender = outbound.recent\n'
           '-        val senderFps = sender?.fps.valid()\n'
           '+        val senderFps = sender?.deliveryFps.valid()\n'
           '         val decoderFps = receiver?.fps.valid()\n'
           '         val presentedFps = receiver?.presentedFps.valid()\n'
           '         val expectedGlassFps =\n'
           '@@ -98,7 +98,6 @@ internal class PhotonFreshnessGovernor {\n'
           '                 senderFps,\n'
           '                 decoderFps\n'
           '             )\n'
           '-                .filter { it > 0.0 }\n'
           '                 .minOrNull()\n'
           '         val glassRatio =\n'
           '             if (\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt',
  'before': 'be8c386df1a33a8d23a4becef277f56d29ad177092cc0df315c788af6824d5a7',
  'after': 'c9680a0922992612b4f2e3c793c398e0a797431a054befe220d9fe18d6a2119d',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt\n'
           'index 69a44284..1d14f022 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt\n'
           '@@ -467,7 +467,7 @@ class VideoCadenceGovernor(\n'
           '             highCadencePressureGate.clearPresentation()\n'
           '         }\n'
           '         val sender = outbound.recent ?: return false\n'
           '-        lastSenderFps = sender.fps.takeIf {\n'
           '+        lastSenderFps = sender.deliveryFps.takeIf {\n'
           '             nowMs >= 0L &&\n'
           '                 sender.intervalMs in FAST_PRESENTATION_MIN_WINDOW_MS..\n'
           '                     FAST_PRESENTATION_MAX_WINDOW_MS &&\n'
           '@@ -509,7 +509,7 @@ class VideoCadenceGovernor(\n'
           '                     receiver != null &&\n'
           '                         receiver.frames >= MIN_MEASURED_FRAMES &&\n'
           '                         (receiver.processingMs ?: 0.0) > budgetMs * '
           'CODEC_PRESSURE_BUDGET_RATIO &&\n'
           '-                        receiver.fps < minOf(requestedFps.toDouble(), sender.fps) * '
           'FPS_DELIVERY_RATIO\n'
           '+                        receiver.fps < minOf(requestedFps.toDouble(), sender.deliveryFps) '
           '* FPS_DELIVERY_RATIO\n'
           '                     )\n'
           ' \n'
           '         val loss = outbound.packetLossRatio ?: 0.0\n'
           '@@ -564,7 +564,7 @@ class VideoCadenceGovernor(\n'
           '         val presentedFps = receiver?.presentedFps\n'
           '         val measuredReceiverFps = receiver?.takeIf { it.frames >= MIN_MEASURED_FRAMES '
           '}?.fps\n'
           '         val expectedPresentationFps = if (presentedFps != null) {\n'
           '-            minOf(requestedFps.toDouble(), sender.fps, measuredReceiverFps ?: '
           'Double.POSITIVE_INFINITY)\n'
           '+            minOf(requestedFps.toDouble(), sender.deliveryFps, measuredReceiverFps ?: '
           'Double.POSITIVE_INFINITY)\n'
           '         } else 0.0\n'
           '         val presentationRatio =\n'
           '             if (presentedFps != null && expectedPresentationFps >= '
           'MIN_PRESENTATION_EXPECTED_FPS) {\n'
           '@@ -789,7 +789,7 @@ class VideoCadenceGovernor(\n'
           '             } ?: return false\n'
           '             val next = if (severePressure) {\n'
           '                 val delivered = buildList {\n'
           '-                    if (sender.frames >= MIN_MEASURED_FRAMES) add(sender.fps)\n'
           '+                    if (sender.frames >= MIN_MEASURED_FRAMES) add(sender.deliveryFps)\n'
           '                     if (receiver != null && receiver.frames >= MIN_MEASURED_FRAMES) '
           'add(receiver.fps)\n'
           '                     if (presentationMeasured && presentedFps != null) add(presentedFps)\n'
           '                 }.minOrNull()\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthSnapshot.kt',
  'before': '41849089bb438fcb145265a574ba6b4bd76cdeaf558ff8cb882d3f18738e569b',
  'after': 'fbe27ba4ef9dd96d0c72ba8cc93e26aa65611943edf35644760fdefc6f8583ac',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthSnapshot.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthSnapshot.kt\n'
           'index fe10c771..cc78bb35 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthSnapshot.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthSnapshot.kt\n'
           '@@ -31,7 +31,8 @@ data class VideoHealthSnapshot(\n'
           '     val jitterEmittedCount: Long? = null,\n'
           '     val sendDelayTotalSeconds: Double? = null,\n'
           '     val recent: VideoHealthWindow? = null,\n'
           '-    val availableOutgoingBitrateBps: Double? = null\n'
           '+    val availableOutgoingBitrateBps: Double? = null,\n'
           '+    val hasSentFrameCounter: Boolean = false\n'
           ' ) {\n'
           '     fun compact(): String {\n'
           '         val primary =\n'
           '@@ -276,7 +277,8 @@ data class VideoHealthSnapshot(\n'
           '                     availableOutgoingBitrateBps = availableOutgoingBitrateBps,\n'
           '                     streamId = selected.id, timestampUs = report.timestampUs,\n'
           '                     processingTotalSeconds = decimal(members["totalEncodeTime"]),\n'
           '-                    sendDelayTotalSeconds = decimal(members["totalPacketSendDelay"])\n'
           '+                    sendDelayTotalSeconds = decimal(members["totalPacketSendDelay"]),\n'
           '+                    hasSentFrameCounter = members["framesSent"] != null\n'
           '                 )\n'
           '             } else {\n'
           '                 VideoHealthSnapshot(\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthWindow.kt',
  'before': 'c30ae7ad506f2bd27fb87cc38b4717eec07b47992880179e1a12e78b1f22ab88',
  'after': '209333e74b14b5d674b879ff1e792752c4fc376d3e31bad23646701881b28c51',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthWindow.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthWindow.kt\n'
           'index 70ed6e63..9bf4ed89 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthWindow.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/VideoHealthWindow.kt\n'
           '@@ -43,10 +43,20 @@ data class VideoHealthWindow(\n'
           '     val postAckPresentMs: Int? = null,\n'
           '     val photonSampleSequence: Long? = null,\n'
           '     val photonSampleAgeMs: Int? = null,\n'
           '-    val photonSampleFresh: Boolean = true\n'
           '+    val photonSampleFresh: Boolean = true,\n'
           '+    /** Completed frames handed to RTP, separately from encoder completions. */\n'
           '+    val sentFrames: Int? = null\n'
           ' ) {\n'
           '     val fps: Double get() = frames * 1000.0 / intervalMs\n'
           ' \n'
           '+    val sentFps: Double?\n'
           '+        get() = sentFrames?.takeIf { it >= 0 && intervalMs > 0 }\n'
           '+            ?.let { it * 1000.0 / intervalMs }\n'
           '+\n'
           '+    // Older/partial reports keep the existing estimate. A measured zero is\n'
           '+    // real zero supply; it must never fall back to the encoded frame count.\n'
           '+    val deliveryFps: Double get() = sentFps ?: fps\n'
           '+\n'
           '     /**\n'
           '      * Receiver freshness budget. WebRTC may intentionally grow its target\n'
           '      * jitter-buffer residence before the measured emitted-frame residence has\n'
           '@@ -86,7 +96,8 @@ data class VideoHealthWindow(\n'
           '             " present=alive age=${it}ms"\n'
           '         }.orEmpty()\n'
           '         val target = jitterTargetMs?.roundToInt()?.let { " target=${it}ms" }.orEmpty()\n'
           '-        return "${fps.roundToInt()}fps ${bitrateBps / 1000}kbps '
           'codec=${processingMs?.roundToInt()}ms jitter=${jitterMs?.roundToInt()}ms$target '
           'drop=$dropped freeze=$freezes queue=${sendQueueMs?.roundToInt()}ms$presentation"\n'
           '+        val sent = sentFps?.roundToInt()?.let { " sent=${it}fps" }.orEmpty()\n'
           '+        return "${fps.roundToInt()}fps$sent ${bitrateBps / 1000}kbps '
           'codec=${processingMs?.roundToInt()}ms jitter=${jitterMs?.roundToInt()}ms$target '
           'drop=$dropped freeze=$freezes queue=${sendQueueMs?.roundToInt()}ms$presentation"\n'
           '     }\n'
           ' }\n'
           ' \n'
           '@@ -173,7 +184,14 @@ class VideoHealthWindowTracker {\n'
           '                         current.jitterTargetTotalSeconds,\n'
           '                         old.jitterTargetTotalSeconds,\n'
           '                         emitted\n'
           '-                    )\n'
           '+                    ),\n'
           '+                sentFrames =\n'
           '+                    if (current.direction == "outbound" &&\n'
           '+                        current.hasSentFrameCounter && old.hasSentFrameCounter) {\n'
           '+                        count(current.framesSecondary, old.framesSecondary)\n'
           '+                    } else {\n'
           '+                        null\n'
           '+                    }\n'
           '             )\n'
           '         )\n'
           '     }\n'},
 {'path': 'app/src/test/java/com/aaris/remoteassist/webrtc/MotionVideoBudgetTest.kt',
  'before': '30a05116b9d22bf74457f9189ee63291f0223d85f0572d391acc5e34163914e6',
  'after': '26c4062c4a0e2381369f21ed451896c7e673e7feb94910778e91d702405bd13c',
  'patch': 'diff --git a/app/src/test/java/com/aaris/remoteassist/webrtc/MotionVideoBudgetTest.kt '
           'b/app/src/test/java/com/aaris/remoteassist/webrtc/MotionVideoBudgetTest.kt\n'
           'index 8fa411f3..b39c75e1 100644\n'
           '--- a/app/src/test/java/com/aaris/remoteassist/webrtc/MotionVideoBudgetTest.kt\n'
           '+++ b/app/src/test/java/com/aaris/remoteassist/webrtc/MotionVideoBudgetTest.kt\n'
           '@@ -21,6 +21,54 @@ class MotionVideoBudgetTest {\n'
           '         assertEquals(720, shortEdge)\n'
           '     }\n'
           ' \n'
           '+    @Test fun regularFifteenFpsSourceDoesNotPayForASixtyFpsCeiling() {\n'
           '+        val budget = MotionVideoBudget()\n'
           '+        budget.primeForMotion(profile, 0L)\n'
           '+        val sparseMotion = sender(fps = 15).copy(\n'
           '+            qualityLimitationReason = "bandwidth",\n'
           '+            availableOutgoingBitrateBps = 700_000.0\n'
           '+        )\n'
           '+\n'
           '+        repeat(12) { index ->\n'
           '+            assertFalse(budget.observe(\n'
           '+                sparseMotion, receiver(fps = 15).copy(maxRenderGapMs = 67),\n'
           '+                sourceFps = 15.0, motionActive = true, targetFps = 60,\n'
           '+                nowMs = (index + 1) * 1_000L, interactionActive = true\n'
           '+            ))\n'
           '+        }\n'
           '+        assertEquals(360, budget.shortEdge)\n'
           "+        // Demand accounting does not lower the source/encoder's FPS ceiling.\n"
           '+        assertEquals(1_800_000, budget.bitrateCeiling(profile, true, 60))\n'
           '+    }\n'
           '+\n'
           '+    @Test fun emergencyRecoveryUsesTheExactRungThatBandwidthApproved() {\n'
           '+        val budget = MotionVideoBudget()\n'
           '+        budget.primeForMotion(profile, 0L)\n'
           '+        val backedUp = sender(fps = 2, encode = 5.0, queue = 350.0).copy(\n'
           '+            qualityLimitationReason = "bandwidth"\n'
           '+        )\n'
           '+        budget.observe(backedUp, null, 60.0, true, 30, 1_000L)\n'
           '+        budget.observe(backedUp, null, 60.0, true, 30, 2_000L)\n'
           '+        assertEquals(180, budget.shortEdge)\n'
           '+\n'
           '+        // 700 kbps covers 240@30 with the 20% recovery margin, but cannot\n'
           '+        // cover 360@30. Recovery must not test 240 and then install 360.\n'
           '+        val recovered = sender().copy(availableOutgoingBitrateBps = 700_000.0)\n'
           '+        repeat(12) { index ->\n'
           '+            budget.observe(recovered, receiver(), 30.0, true, 30,\n'
           '+                13_000L + index * 1_000L)\n'
           '+        }\n'
           '+        assertEquals(240, budget.shortEdge)\n'
           '+        assertEquals(240, budget.apply(profile, true).captureWidthPx)\n'
           '+        assertEquals(500_000, budget.bitrateCeiling(profile, true, 30))\n'
           '+\n'
           '+        repeat(24) { index ->\n'
           '+            assertFalse(budget.observe(recovered, receiver(), 30.0, true, 30,\n'
           '+                25_000L + index * 1_000L))\n'
           '+        }\n'
           '+        assertEquals(240, budget.shortEdge)\n'
           '+    }\n'
           '+\n'
           '     @Test fun retainedGlassHitchCannotBecomeASecondResolutionPressureVote() {\n'
           '         val budget = nativeWarmBudget()\n'
           '         val hitch = receiver(presented = 10).copy(maxRenderGapMs = 160)\n'},
 {'path': 'app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt',
  'before': '01f4077b9c5ee9f1d73aeb6ee179e2302d6359dd5a1fb429125041b424309cf7',
  'after': 'a164261ae6f81afdaa4ffc509c0394a7c8c4a0d1e4e700863fcdc106469ee14c',
  'patch': 'diff --git a/app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt '
           'b/app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt\n'
           'index 71c6237a..be7896de 100644\n'
           '--- a/app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt\n'
           '+++ b/app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt\n'
           '@@ -88,6 +88,19 @@ class PhotonFreshnessGovernorTest {\n'
           '         assertTrue(p.allowResolutionRecovery)\n'
           '     }\n'
           ' \n'
           '+    @Test fun zeroSentSupplyCannotProveCurrentDeliveryFromBufferedGlass() {\n'
           '+        val g = PhotonFreshnessGovernor()\n'
           '+        val encoded = outbound()\n'
           '+        val unsent = encoded.copy(recent = encoded.recent!!.copy(sentFrames = 0))\n'
           '+        repeat(6) { index ->\n'
           '+            val p = g.observe(unsent, receiver(), 60, false,\n'
           '+                1_000L + index * 500L)\n'
           '+            assertNull(p.glassDeliveryRatio)\n'
           '+            assertFalse(p.allowCadencePromotion)\n'
           '+            assertFalse(p.allowResolutionRecovery)\n'
           '+        }\n'
           '+    }\n'
           '+\n'
           '     @Test\n'
           '     fun heldGlassWindowDoesNotBecomeAnotherCleanVote() {\n'
           '         val g = PhotonFreshnessGovernor()\n'},
 {'path': 'app/src/test/java/com/aaris/remoteassist/webrtc/PresentationSupplyTest.kt',
  'before': '3343d5795e100b65b289676738d9809114f749b9ad8a932abee5b56df685bd30',
  'after': '30e2267ff7a7ef3693b933a4f97f1a784e88581343ba2852c56527afce9f3493',
  'patch': 'diff --git a/app/src/test/java/com/aaris/remoteassist/webrtc/PresentationSupplyTest.kt '
           'b/app/src/test/java/com/aaris/remoteassist/webrtc/PresentationSupplyTest.kt\n'
           'index 9c989db1..6c6e59f4 100644\n'
           '--- a/app/src/test/java/com/aaris/remoteassist/webrtc/PresentationSupplyTest.kt\n'
           '+++ b/app/src/test/java/com/aaris/remoteassist/webrtc/PresentationSupplyTest.kt\n'
           '@@ -53,6 +53,30 @@ class PresentationSupplyTest {\n'
           '         assertEquals(60, governor.cap)\n'
           '     }\n'
           ' \n'
           '+    @Test fun encodedFramesWaitingForRtpAreNotSuppliedToTheDisplay() {\n'
           '+        val governor = VideoCadenceGovernor(60)\n'
           '+        val encoded = sender(60)\n'
           '+        val sentThirty = encoded.copy(\n'
           '+            recent = encoded.recent!!.copy(sentFrames = 30)\n'
           '+        )\n'
           '+        for (now in 1_000L..3_000L step 500L) {\n'
           '+            assertFalse(governor.observe(sentThirty, null, 60, now,\n'
           '+                producerFps = 60.0))\n'
           '+            assertFalse(present(governor, nowMs = now + 100L))\n'
           '+        }\n'
           '+        assertEquals(60, governor.cap)\n'
           '+    }\n'
           '+\n'
           '+    @Test fun measuredZeroSentFramesCannotBecomeSixtyFpsOfGlassPressure() {\n'
           '+        val governor = VideoCadenceGovernor(60)\n'
           '+        val encoded = sender(60)\n'
           '+        assertFalse(governor.observe(encoded.copy(\n'
           '+            recent = encoded.recent!!.copy(sentFrames = 0)\n'
           '+        ), null, 60, 1_000L, producerFps = 60.0))\n'
           '+        assertFalse(present(governor, frames = 5, gapMs = 180))\n'
           '+        assertEquals(60, governor.cap)\n'
           '+    }\n'
           '+\n'
           '     @Test fun sparseScreenUpdatesMustNotAccumulateFalseGlassPressure() {\n'
           '         val governor = VideoCadenceGovernor(60)\n'
           '         for (now in 1_000L..5_000L step 500L) {\n'},
 {'path': 'app/src/test/java/com/aaris/remoteassist/webrtc/SentFrameSupplyTest.kt',
  'before': None,
  'after': '5ee50cf64cc1b8e7be61b4f9e160152bcf42ec5c9a7f95b9d17f478d9a2d4bf0',
  'patch': 'diff --git a/app/src/test/java/com/aaris/remoteassist/webrtc/SentFrameSupplyTest.kt '
           'b/app/src/test/java/com/aaris/remoteassist/webrtc/SentFrameSupplyTest.kt\n'
           'new file mode 100644\n'
           'index 00000000..ac013e05\n'
           '--- /dev/null\n'
           '+++ b/app/src/test/java/com/aaris/remoteassist/webrtc/SentFrameSupplyTest.kt\n'
           '@@ -0,0 +1,67 @@\n'
           '+package com.aaris.remoteassist.webrtc\n'
           '+\n'
           '+import org.junit.Assert.*\n'
           '+import org.junit.Test\n'
           '+import org.webrtc.RTCStats\n'
           '+import org.webrtc.RTCStatsReport\n'
           '+\n'
           '+class SentFrameSupplyTest {\n'
           '+    private fun outbound(time: Long, encoded: Long, sent: Long?): VideoHealthSnapshot {\n'
           '+        val members = mutableMapOf<String, Any>(\n'
           '+            "kind" to "video", "framesEncoded" to encoded,\n'
           '+            "bytesSent" to encoded * 1_000, "packetsSent" to encoded * 3,\n'
           '+            "totalEncodeTime" to encoded * 0.010,\n'
           '+            "totalPacketSendDelay" to encoded * 3 * 0.005\n'
           '+        )\n'
           '+        sent?.let { members["framesSent"] = it }\n'
           '+        val stat = RTCStats(time, "outbound-rtp", "screen", members)\n'
           '+        return checkNotNull(VideoHealthSnapshot.from(\n'
           '+            RTCStatsReport(time, mapOf("screen" to stat)), PeerRole.HOST\n'
           '+        ))\n'
           '+    }\n'
           '+\n'
           '+    @Test fun encodeCostAndTransmittedCadenceUseTheirOwnCounters() {\n'
           '+        val tracker = VideoHealthWindowTracker()\n'
           '+        tracker.sample(outbound(1_000_000L, 100, 100))\n'
           '+        val window = checkNotNull(tracker.sample(\n'
           '+            outbound(2_000_000L, 160, 130)\n'
           '+        ).recent)\n'
           '+        assertEquals(60, window.frames)\n'
           '+        assertEquals(30, window.sentFrames)\n'
           '+        assertEquals(60.0, window.fps, 0.001)\n'
           '+        assertEquals(30.0, window.deliveryFps, 0.001)\n'
           '+        assertEquals(10.0, window.processingMs!!, 0.001)\n'
           '+        assertEquals(5.0, window.sendQueueMs!!, 0.001)\n'
           '+        assertTrue(window.compact().contains("sent=30fps"))\n'
           '+    }\n'
           '+\n'
           '+    @Test fun measuredZeroSupplyRemainsZero() {\n'
           '+        val tracker = VideoHealthWindowTracker()\n'
           '+        tracker.sample(outbound(1_000_000L, 100, 100))\n'
           '+        val window = tracker.sample(outbound(2_000_000L, 160, 100)).recent!!\n'
           '+        assertEquals(0, window.sentFrames)\n'
           '+        assertEquals(0.0, window.deliveryFps, 0.001)\n'
           '+        assertEquals(60.0, window.fps, 0.001)\n'
           '+    }\n'
           '+\n'
           '+    @Test fun absentOrResetSentCountersDoNotInventAZeroOrNegativeDelta() {\n'
           '+        val tracker = VideoHealthWindowTracker()\n'
           '+        tracker.sample(outbound(1_000_000L, 100, 100))\n'
           '+        val missing = tracker.sample(outbound(2_000_000L, 160, null)).recent!!\n'
           '+        assertNull(missing.sentFrames)\n'
           '+        assertEquals(missing.fps, missing.deliveryFps, 0.001)\n'
           '+        assertNull(tracker.sample(outbound(3_000_000L, 220, 10)).recent!!.sentFrames)\n'
           '+        assertEquals(30, tracker.sample(outbound(4_000_000L, 280, '
           '40)).recent!!.sentFrames)\n'
           '+        assertNull(tracker.sample(outbound(5_000_000L, 340, 2)).recent!!.sentFrames)\n'
           '+        assertEquals(30, tracker.sample(outbound(6_000_000L, 400, '
           '32)).recent!!.sentFrames)\n'
           '+    }\n'
           '+\n'
           '+    @Test fun pacerCanDrainOlderFramesWithoutCorruptingEncodeCost() {\n'
           '+        val tracker = VideoHealthWindowTracker()\n'
           '+        tracker.sample(outbound(1_000_000L, 100, 70))\n'
           '+        val drained = tracker.sample(outbound(2_000_000L, 110, 100)).recent!!\n'
           '+        assertEquals(10.0, drained.fps, 0.001)\n'
           '+        assertEquals(30.0, drained.deliveryFps, 0.001)\n'
           '+        assertEquals(10.0, drained.processingMs!!, 0.001)\n'
           '+    }\n'
           '+}\n'}]


def digest(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None


def current(path):
    return path.read_bytes() if path.exists() else None


def restore(path, data, mode):
    if data is None:
        path.unlink(missing_ok=True)
        return
    descriptor, temporary = tempfile.mkstemp(prefix=".frame-flow-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--check", action="store_true", help="validate without modifying source")
    args = parser.parse_args()
    root = args.root.resolve()
    pending = []
    originals = {}
    try:
        if not (root / "app/src/main").is_dir():
            raise RuntimeError("Not an Aaris Remote project: " + str(root))
        for entry in PATCHES:
            path = root / entry["path"]
            if path.is_symlink() or not path.resolve().is_relative_to(root):
                raise RuntimeError("Refusing linked source: " + entry["path"])
            if any(parent.is_symlink() for parent in path.parents if parent != root and parent.is_relative_to(root)):
                raise RuntimeError("Refusing linked source directory: " + entry["path"])
            data = current(path)
            originals[path] = (data, stat.S_IMODE(path.stat().st_mode) if data is not None else 0o644)
            existing = digest(data)
            if existing == entry["after"]:
                continue
            if existing != entry["before"]:
                raise RuntimeError("Source differs from the audited baseline: " + entry["path"])
            pending.append(entry)
        patch = "".join(entry["patch"] for entry in pending)
        if pending:
            subprocess.run(["git", "apply", "--check", "--whitespace=error", "-"],
                           cwd=root, input=patch, text=True, check=True, capture_output=True)
        if args.check:
            print("Validated; " + str(len(pending)) + " files need the fix.")
            return 0
        # Recheck all originals, including already-fixed files, before mutation.
        for path, (data, _) in originals.items():
            if current(path) != data:
                raise RuntimeError("Source changed during validation: " + str(path.relative_to(root)))
        try:
            if pending:
                subprocess.run(["git", "apply", "--whitespace=error", "-"],
                               cwd=root, input=patch, text=True, check=True, capture_output=True)
            for entry in PATCHES:
                if digest(current(root / entry["path"])) != entry["after"]:
                    raise RuntimeError("Post-apply verification failed: " + entry["path"])
        except BaseException:
            for entry in reversed(pending):
                path = root / entry["path"]
                if path.is_symlink() or not path.resolve().is_relative_to(root):
                    print("Concurrent path change preserved: " + entry["path"], file=sys.stderr)
                    continue
                data, mode = originals[path]
                if digest(current(path)) == entry["after"]:
                    restore(path, data, mode)
                elif current(path) != data:
                    print("Concurrent edit preserved: " + entry["path"], file=sys.stderr)
            raise
        print("Verified frame-flow corrections applied." if pending else "Verified; already fixed.")
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        print("Fix refused: " + detail, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
