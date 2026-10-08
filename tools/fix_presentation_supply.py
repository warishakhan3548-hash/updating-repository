#!/usr/bin/env python3
"""Apply the audited presentation-supply fixes once, with exact source guards.

Usage: python3 tools/fix_presentation_supply.py [--root REPOSITORY] [--check]
Already-fixed files are preserved. Modified or unrelated versions are refused
before any file is changed. Requires Python 3.10+ and git.
"""
import argparse
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

PATCHES = [{'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt',
  'before': 'b7913017e0a3aaca751f36a20a9a8decdbe4d7b10c0b7805b8fed8d629722186',
  'after': 'be8c386df1a33a8d23a4becef277f56d29ad177092cc0df315c788af6824d5a7',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt\n'
           'index 46e22ec..69a4428 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/VideoCadenceGovernor.kt\n'
           '@@ -21,6 +21,11 @@ class VideoCadenceGovernor(\n'
           '     private var lastOverloadAtMs = Long.MIN_VALUE / 2\n'
           '     private var lastDecision = "startup"\n'
           '     private var lastDeadlineSummary = "deadline=unknown"\n'
           '+    // Completed upstream supply, not the requested source ceiling. Scalar\n'
           '+    // evidence only; capture/RTP frames remain owned by the native pipeline.\n'
           '+    private var lastSenderIdentity: Pair<String, String?>? = null\n'
           '+    private var lastSenderFps: Double? = null\n'
           '+    private var lastSenderAtMs = Long.MIN_VALUE / 2\n'
           '     private val highCadenceProbe = HighCadenceProbe()\n'
           '     private val highCadencePressureGate = HighCadencePressureGate()\n'
           '     val probingHighCadence: Boolean get() = highCadenceProbe.probing\n'
           '@@ -316,6 +321,10 @@ class VideoCadenceGovernor(\n'
           '      * FPS or estimate bandwidth. GCC/TWCC and the full telemetry governor remain\n'
           '      * authoritative for network adaptation and recovery.\n'
           '      *\n'
           '+     * A requested 60 fps ceiling does not prove 60 frames were supplied. Compare\n'
           '+     * glass cadence with recent completed sender supply; sparse/unknown/expired\n'
           '+     * supply cannot establish a fast display-overload vote.\n'
           '+     *\n'
           '      * At high cadence one trustworthy hitch earns only one fine relief step\n'
           '      * (for example 60 -> 58). A large fall toward 30 still requires severe\n'
           '      * presentation/pipeline evidence. The bounded cooldown plus one-step rule\n'
           '@@ -350,12 +359,26 @@ class VideoCadenceGovernor(\n'
           '             return false\n'
           '         }\n'
           ' \n'
           '+        val suppliedFps = lastSenderFps\n'
           '+        if (\n'
           '+            suppliedFps == null ||\n'
           '+            nowMs - lastSenderAtMs !in 0L..FAST_PRESENTATION_MAX_SENDER_AGE_MS\n'
           '+        ) {\n'
           '+            highCadencePressureGate.clearPresentation()\n'
           '+            return false\n'
           '+        }\n'
           '+        val expectedFps = minOf(effectiveFps.toDouble(), suppliedFps)\n'
           '+        if (expectedFps < MIN_PRESENTATION_EXPECTED_FPS) {\n'
           '+            highCadencePressureGate.clearPresentation()\n'
           '+            return false\n'
           '+        }\n'
           '+\n'
           '         val measuredFps =\n'
           '             renderedFrames * 1_000.0 / intervalMs.toDouble()\n'
           '         val deliveryRatio =\n'
           '-            measuredFps / effectiveFps.toDouble()\n'
           '+            measuredFps / expectedFps\n'
           '         val frameBudgetMs =\n'
           '-            1_000.0 / effectiveFps.toDouble()\n'
           '+            1_000.0 / expectedFps\n'
           ' \n'
           '         val severeGapMs =\n'
           '             maxOf(\n'
           '@@ -437,7 +460,21 @@ class VideoCadenceGovernor(\n'
           '         maximumFps: Int = maxFps,\n'
           '         allowHighCadenceProbe: Boolean = true\n'
           '     ): Boolean {\n'
           '+        val senderIdentity = outbound.streamId to outbound.codec\n'
           '+        if (senderIdentity != lastSenderIdentity) {\n'
           '+            lastSenderIdentity = senderIdentity\n'
           '+            lastSenderFps = null\n'
           '+            highCadencePressureGate.clearPresentation()\n'
           '+        }\n'
           '         val sender = outbound.recent ?: return false\n'
           '+        lastSenderFps = sender.fps.takeIf {\n'
           '+            nowMs >= 0L &&\n'
           '+                sender.intervalMs in FAST_PRESENTATION_MIN_WINDOW_MS..\n'
           '+                    FAST_PRESENTATION_MAX_WINDOW_MS &&\n'
           '+                sender.frames in 0..2048 &&\n'
           '+                it.isFinite() && it >= 0.0\n'
           '+        }\n'
           '+        lastSenderAtMs = nowMs\n'
           ' \n'
           '         if (\n'
           '             cap < HIGH_CADENCE_FAST_RELIEF_FPS ||\n'
           '@@ -971,6 +1008,7 @@ class VideoCadenceGovernor(\n'
           '          */\n'
           '         const val FAST_PRESENTATION_MIN_WINDOW_MS = 500\n'
           '         const val FAST_PRESENTATION_MAX_WINDOW_MS = 2_000\n'
           '+        const val FAST_PRESENTATION_MAX_SENDER_AGE_MS = 1_500L\n'
           '         const val FAST_PRESENTATION_MIN_FRAMES = 5\n'
           '         const val FAST_PRESENTATION_MIN_CADENCE_FPS = 45\n'
           '         const val FAST_PRESENTATION_CHANGE_INTERVAL_MS = 450L\n'},
 {'path': 'app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt',
  'before': '6b5d6793cfc2bcb1a1bf5ed2465be088ade8a1327d988f46d783fadd7db40adc',
  'after': '73625a6d3ce35e0f1309e6c8bf2feb0a9763de387f1fa1c422e4c55213b60f03',
  'patch': 'diff --git a/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt '
           'b/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
           'index 200c3e1..44e3580 100644\n'
           '--- a/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
           '+++ b/app/src/main/java/com/aaris/remoteassist/webrtc/MotionVideoBudget.kt\n'
           '@@ -184,9 +184,12 @@ internal class MotionVideoBudget {\n'
           '         val decodePressure = received != null && (decodeMs ?: 0.0) > frameMs * 0.85 '
           '&&\n'
           '             received.fps < minOf(sender.fps, goal.toDouble()) * 0.85\n'
           '         val expectedPresentation = minOf(goal.toDouble(), sender.fps, received?.fps '
           '?: 0.0)\n'
           '-        val presentationPressure = expectedPresentation >= 10.0 && '
           'received?.presentedFps?.let {\n'
           '-            it < expectedPresentation * 0.8 || (received.maxRenderGapMs ?: 0) >= 150\n'
           '-        } == true\n'
           '+        // Held EGL cadence bridges independently phased stats clocks. It may\n'
           '+        // block recovery, but must not become another resolution-pressure vote.\n'
           '+        val presentationPressure = received?.presentationSampleFresh != false &&\n'
           '+            expectedPresentation >= 10.0 && received?.presentedFps?.let {\n'
           '+                it < expectedPresentation * 0.8 || (received.maxRenderGapMs ?: 0) >= '
           '150\n'
           '+            } == true\n'
           '         val measuredSourceFps = sourceFps.valid()\n'
           ' \n'
           '         /*\n'},
 {'path': 'app/build.gradle.kts',
  'before': '31f54cfd1ee10492b72b9f58eb2afd05704531c1a5c9ce78643bc0adbefb4924',
  'after': '7b6cd249fe90bce220ef778f9625f7f76f64b62c0e87923b0f9967436701997f',
  'patch': 'diff --git a/app/build.gradle.kts b/app/build.gradle.kts\n'
           'index 4e90bab..32adf98 100644\n'
           '--- a/app/build.gradle.kts\n'
           '+++ b/app/build.gradle.kts\n'
           '@@ -47,8 +47,8 @@ android {\n'
           '         applicationId = "com.aaris.remoteassist"\n'
           '         minSdk = 26\n'
           '         targetSdk = 36\n'
           '-        versionCode = 146\n'
           '-        versionName = "1.9.58"\n'
           '+        versionCode = 147\n'
           '+        versionName = "1.9.59"\n'
           '         testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"\n'
           '     }\n'
           '     buildFeatures { buildConfig = true }\n'}]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def restore(path, data, mode):
    fd, name = tempfile.mkstemp(prefix=".presentation-fix-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
            os.fchmod(out.fileno(), mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--check", action="store_true", help="validate without applying")
    args = parser.parse_args()
    root = args.root.resolve()
    originals = {}
    pending = []
    try:
        for item in PATCHES:
            path = root / item["path"]
            if path.is_symlink() or not path.resolve().is_relative_to(root):
                raise RuntimeError("Refusing linked source: " + item["path"])
            data = path.read_bytes()
            originals[path] = (data, stat.S_IMODE(path.stat().st_mode))
            current = digest(data)
            if current == item["after"]:
                print("Already fixed: " + item["path"])
            elif current == item["before"]:
                pending.append(item)
            else:
                raise RuntimeError("Source differs from the audited baseline: " + item["path"])
        for item in pending:
            subprocess.run(["git", "apply", "--check", "-"], cwd=root,
                           input=item["patch"], text=True, check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if args.check:
            print("Validated; " + str(len(pending)) + " files need the fix.")
            return 0
        touched = []
        try:
            for item in pending:
                path = root / item["path"]
                if path.read_bytes() != originals[path][0]:
                    raise RuntimeError("Source changed during validation: " + item["path"])
                touched.append(item)
                subprocess.run(["git", "apply", "-"], cwd=root,
                               input=item["patch"], text=True, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for item in PATCHES:
                if digest((root / item["path"]).read_bytes()) != item["after"]:
                    raise RuntimeError("Post-apply verification failed: " + item["path"])
        except BaseException:
            for item in touched:
                path = root / item["path"]
                if digest(path.read_bytes()) == item["after"]:
                    data, mode = originals[path]
                    restore(path, data, mode)
                elif path.read_bytes() != originals[path][0]:
                    print("Concurrent edit preserved: " + item["path"], file=sys.stderr)
            raise
        print("Verified presentation-supply fixes applied." if pending else "Verified; no changes needed.")
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print("Fix refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
