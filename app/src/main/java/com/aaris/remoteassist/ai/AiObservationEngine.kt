package com.aaris.remoteassist.ai

import android.content.Context
import android.os.SystemClock
import android.util.Base64
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.AiSnapshotProvider
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.FrameImageEncoder
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Called on Main; pixel encoding runs off Main. No image archive or unbounded frame queue. */
class AiObservationEngine(private val context: Context, private val snapshots: AiSnapshotProvider) {
    val ledger = AiScreenLedger()
    private var lastFingerprint: ByteArray? = null
    private var width = 0
    private var height = 0
    private var rotation = 0
    private var issuedPackage = ""

    fun changed() = ledger.changed(SystemClock.elapsedRealtime())
    fun invalidate() = ledger.invalidate(SystemClock.elapsedRealtime())

    suspend fun settle() {
        val start = SystemClock.elapsedRealtime()
        delay(100)
        while (SystemClock.elapsedRealtime() - start < 650 && SystemClock.elapsedRealtime() - ledger.changedAtMs < 120) delay(40)
    }

    suspend fun observe(detail: Boolean = false): JSONObject {
        repeat(2) { attempt ->
            settle()
            val version = ledger.version
            val ui = AssistAccessibilityService.aiSnapshot() ?: return error("DEVICE_LOCKED_OR_ACCESSIBILITY_OFF")
            val geometry = CaptureProfile.current(context, CaptureTier.BALANCED)
            val frame = snapshots.fresh()
            if (!geometryMatches(frame, geometry)) { invalidate(); return error("CAPTURE_GEOMETRY_CHANGED") }
            val hideAll = ui.sensitiveFocus || ui.packageName == context.packageName
            val encoded = withContext(Dispatchers.Default) {
                FrameImageEncoder.encode(frame, if (detail) 2400 else 1280, ui.masks, geometry.displayWidthPx, geometry.displayHeightPx, hideAll)
            }
            val stable = version == ledger.version
            if (!stable && attempt == 0) return@repeat
            val id = UUID.randomUUID().toString()
            if (stable) {
                width = geometry.displayWidthPx; height = geometry.displayHeightPx; rotation = frame.rotation
                issuedPackage = ui.packageName
                lastFingerprint = AiVisualFingerprint.sample(frame.nv21, frame.width, frame.height)
                ledger.issue(id, SystemClock.elapsedRealtime())
            } else ledger.consume()
            return JSONObject().put("observationId", id).put("screenVersion", version)
                .put("capturedAtElapsedMs", frame.receivedAtMs).put("settled", stable)
                .put("currentPackage", ui.packageName).put("uiHints", if (hideAll) JSONArray() else ui.hints)
                .put("treeTruncated", ui.truncated).put("redacted", hideAll || ui.masks.isNotEmpty())
                .put("display", JSONObject().put("width", geometry.displayWidthPx).put("height", geometry.displayHeightPx)
                    .put("coordinateSpace", "full-upright-display-normalized-0-to-1"))
                .put("image", JSONObject().put("mimeType", "image/jpeg").put("width", encoded.width).put("height", encoded.height)
                    .put("data", Base64.encodeToString(encoded.bytes, Base64.NO_WRAP)))
                .apply {
                    if (!stable) put("error", "SCREEN_CHANGING")
                    if (ui.packageName == context.packageName) put("note", "Connector setup is hidden to protect the access link. Use home to open the phone launcher.")
                    else if (ui.sensitiveFocus) put("note", "Sensitive input is local-only; use back or home to leave it.")
                }
        }
        return error("CAPTURE_UNAVAILABLE")
    }

    suspend fun validate(args: JSONObject): Boolean {
        if (!ledger.valid(args.getString("observationId"), args.getLong("screenVersion"), SystemClock.elapsedRealtime())) return false
        val geometry = CaptureProfile.current(context, CaptureTier.BALANCED)
        if (geometry.displayWidthPx != width || geometry.displayHeightPx != height) { invalidate(); return false }
        val ui = AssistAccessibilityService.aiSnapshot() ?: return false
        if (ui.packageName != issuedPackage) { invalidate(); return false }
        if ((ui.sensitiveFocus || ui.packageName == context.packageName) && args.getString("action") !in setOf("home", "back", "recents")) return false
        val fresh = snapshots.fresh()
        if (fresh.rotation != rotation || !geometryMatches(fresh, geometry) ||
            AiVisualFingerprint.materiallyDifferent(lastFingerprint ?: byteArrayOf(), AiVisualFingerprint.sample(fresh.nv21, fresh.width, fresh.height))) {
            invalidate(); return false
        }
        return ledger.valid(args.getString("observationId"), args.getLong("screenVersion"), SystemClock.elapsedRealtime())
    }

    fun geometry(): Pair<Int, Int> = width to height
    private fun geometryMatches(frame: AiRawFrame, profile: CaptureProfile): Boolean {
        val w = if (frame.rotation % 180 == 0) frame.width else frame.height
        val h = if (frame.rotation % 180 == 0) frame.height else frame.width
        val ratio = profile.displayWidthPx.toDouble() / profile.displayHeightPx
        return kotlin.math.abs(w.toDouble() / h - ratio) <= 0.015
    }
    private fun error(code: String) = JSONObject().put("error", code).put("applied", false)
}
