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

PATCHES = [{'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt',
  'before': '516f3347ab95292093bfd8466de9de18d10860434d1f36be8961067a4e14bea5',
  'after': 'c6134f19fcbb056541cb47a02aaba22ba10ef4f95670dfa6bf264510d7d130e4',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt\n'
           'index f4c4b772..757652fa 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/HostWebRtcSession.kt\n'
           '@@ -1249,7 +1249,7 @@ class HostWebRtcSession(\n'
           '                     append(fps(sourceFps))\n'
           '                     append(" target=")\n'
           '                     append(effective.fps)\n'
           '-                    append("fps send=")\n'
           '+                    append("fps encode=")\n'
           '                     append(fps(qdSender?.fps))\n'
           '                     append(" decode=")\n'
           '                     append(fps(receiver?.fps))\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt',
  'before': '7549ffb437230109b1b0079bec96237311e94afe0371381f5bcc02ace83f6539',
  'after': '5783834dffb11eab9c6dd29e7cd28b2353aa3e47157ff3cda535cd5075362feb',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
           'index af0a354d..dfa18be0 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
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
           '@@ -486,7 +494,7 @@ internal class MotionVideoBudget {\n'
           '             // relief stays enabled, but do not also enlarge trial frames.\n'
           '             healthySamples = if (healthy && allowResolutionRecovery) healthySamples + '
           '1 else 0\n'
           '             if (healthySamples >= 12 && nowMs - changedAtMs >= 12_000L && shortEdge < '
           '720) {\n'
           '-                shortEdge = when { shortEdge < 360 -> 360; shortEdge < 540 -> 540; '
           'else -> 720 }\n'
           '+                shortEdge = nextRecoveryRung\n'
           '                 changedAtMs = nowMs\n'
           '                 healthySamples = 0\n'
           '                 resetResidenceGrowth()\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt',
  'before': '44a24f9314f32ef63b9e04b01af5884172d627a165beb658cf10e43ac52c43fb',
  'after': '91b82d02a5d540b267a40e4e6692d267ecaccfaf4b39de30cc0bb94d1c98036e',
  'patch': 'diff --git '
           'a/app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt\n'
           'index 4d0e31f1..c9a98b00 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernor.kt\n'
           '@@ -92,13 +92,15 @@ internal class PhotonFreshnessGovernor {\n'
           '         val senderFps = sender?.fps.valid()\n'
           '         val decoderFps = receiver?.fps.valid()\n'
           '         val presentedFps = receiver?.presentedFps.valid()\n'
           '+        // A measured zero is no media supply, not an unknown counter. Dropping\n'
           '+        // it would compare a quiet stream against the requested FPS ceiling\n'
           '+        // and manufacture a display stall from an empty presentation window.\n'
           '         val expectedGlassFps =\n'
           '             listOfNotNull(\n'
           '                 targetFps.toDouble().takeIf { it > 0.0 },\n'
           '                 senderFps,\n'
           '                 decoderFps\n'
           '             )\n'
           '-                .filter { it > 0.0 }\n'
           '                 .minOrNull()\n'
           '         val glassRatio =\n'
           '             if (\n'},
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
  'after': '29e18f35088839a573793844b5d24a1eefb2e6e78402910d72743a6b978a9067',
  'patch': 'diff --git '
           'a/app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt '
           'b/app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt\n'
           'index 71c6237a..2dc13e10 100644\n'
           '--- a/app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt\n'
           '+++ b/app/src/test/java/com/aaris/remoteassist/webrtc/PhotonFreshnessGovernorTest.kt\n'
           '@@ -88,6 +88,32 @@ class PhotonFreshnessGovernorTest {\n'
           '         assertTrue(p.allowResolutionRecovery)\n'
           '     }\n'
           ' \n'
           '+    @Test fun zeroMediaSupplyDoesNotInventPresentationPressureOrDeliveryProof() {\n'
           '+        for (glass in listOf(receiver(fps = 0), receiver())) {\n'
           '+            val g = PhotonFreshnessGovernor()\n'
           '+            repeat(6) { index ->\n'
           '+                val p = g.observe(outbound(fps = 0), glass, 60, false,\n'
           '+                    1_000L + index * 500L)\n'
           '+                assertEquals(PhotonFreshnessState.UNKNOWN, p.state)\n'
           '+                assertNull(p.glassDeliveryRatio)\n'
           '+                assertEquals(0, p.cleanGlassWindows)\n'
           '+                assertFalse(p.allowCadencePromotion)\n'
           '+                assertFalse(p.allowResolutionRecovery)\n'
           '+            }\n'
           '+        }\n'
           '+    }\n'
           '+\n'
           '+    @Test fun zeroMediaSupplyStillRetainsIndependentQueuePressure() {\n'
           '+        val p = PhotonFreshnessGovernor().observe(\n'
           '+            outbound(fps = 0, queueMs = 350.0), receiver(fps = 0),\n'
           '+            60, false, 1_000L\n'
           '+        )\n'
           '+        assertEquals(PhotonFreshnessState.PRESSURE, p.state)\n'
           '+        assertNull(p.glassDeliveryRatio)\n'
           '+        assertFalse(p.allowCadencePromotion)\n'
           '+        assertFalse(p.allowResolutionRecovery)\n'
           '+    }\n'
           '+\n'
           '     @Test\n'
           '     fun heldGlassWindowDoesNotBecomeAnotherCleanVote() {\n'
           '         val g = PhotonFreshnessGovernor()\n'}]


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
