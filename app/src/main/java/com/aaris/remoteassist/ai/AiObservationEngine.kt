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

data class AiActionValidation(val error: String? = null, val stillValid: () -> Boolean = { false })

/** Main-thread owner. Events guide settling; fresh pixels and target semantics authorize actions. */
class AiObservationEngine internal constructor(
    private val ownPackage: String,
    private val display: () -> CaptureProfile,
    private val uiSnapshot: () -> AiUiSnapshot?,
    private val freshFrame: suspend () -> AiRawFrame,
    private val now: () -> Long = SystemClock::elapsedRealtime,
    private val pause: suspend (Long) -> Unit = { delay(it) },
    private val encodeFrame: (AiRawFrame, Int, List<android.graphics.Rect>, Int, Int, Boolean) -> FrameImageEncoder.Encoded = FrameImageEncoder::encode
) {
    constructor(context: Context, snapshots: AiSnapshotProvider) : this(
        context.packageName, { CaptureProfile.current(context, CaptureTier.BALANCED) },
        AssistAccessibilityService::aiSnapshot, snapshots::fresh
    )

    val ledger = AiScreenLedger()
    private var lastFingerprint: ByteArray? = null
    private var issuedUi: AiUiSnapshot? = null
    private var width = 0
    private var height = 0
    private var rotation = 0

    fun changed() = ledger.changed(now())
    fun invalidate() = ledger.invalidate(now())

    private suspend fun settle() {
        val start = now()
        while (true) {
            val current = now()
            val elapsed = current - start
            val quietFor = current - ledger.changedAtMs
            if (quietFor >= QUIET_WINDOW_MS || elapsed >= MAX_SETTLE_MS) return

            val remainingQuiet = (QUIET_WINDOW_MS - quietFor).coerceAtLeast(1L)
            val remainingBudget = (MAX_SETTLE_MS - elapsed).coerceAtLeast(1L)
            pause(minOf(SETTLE_POLL_MS, remainingQuiet, remainingBudget))
        }
    }

    suspend fun observe(detail: Boolean = false): JSONObject {
        repeat(2) { attempt ->
            settle()
            val epoch = ledger.invalidationGeneration
            val revision = ledger.eventRevision
            val before = uiSnapshot() ?: return error("DEVICE_LOCKED_OR_ACCESSIBILITY_OFF")
            val geometry = display()
            val frame = freshFrame()
            if (!geometryMatches(frame, geometry)) { invalidate(); return error("CAPTURE_GEOMETRY_CHANGED") }
            val ui = uiSnapshot() ?: return error("DEVICE_LOCKED_OR_ACCESSIBILITY_OFF")
            // Never publish pixels if privacy masks or foreground window changed
            // during capture. Ordinary animated text may keep moving.
            if (!samePrivacyContext(before, ui)) {
                if (attempt == 0) return@repeat
                return error("SCREEN_CHANGING")
            }
            val hideAll = ui.sensitiveFocus || ui.packageName == ownPackage
            val (encoded, fingerprint) = withContext(Dispatchers.Default) {
                encodeFrame(frame, if (detail) 2400 else 1280, ui.masks,
                    geometry.displayWidthPx, geometry.displayHeightPx, hideAll) to
                    AiVisualFingerprint.sample(frame.nv21, frame.width, frame.height, frame.rotation)
            }
            val after = uiSnapshot() ?: return error("DEVICE_LOCKED_OR_ACCESSIBILITY_OFF")
            if (epoch != ledger.invalidationGeneration) return error("OBSERVATION_INVALIDATED")
            if (!samePrivacyContext(ui, after)) {
                if (attempt == 0) return@repeat
                return error("SCREEN_CHANGING")
            }
            val stable = revision == ledger.eventRevision
            val id = UUID.randomUUID().toString()
            width = geometry.displayWidthPx; height = geometry.displayHeightPx; rotation = frame.rotation
            issuedUi = ui; lastFingerprint = fingerprint
            ledger.issue(id, now())
            return JSONObject().put("observationId", id).put("screenVersion", ledger.version)
                .put("capturedAtElapsedMs", frame.receivedAtMs).put("settled", stable)
                .put("currentPackage", ui.packageName).put("uiHints", if (hideAll) JSONArray() else ui.hints)
                .put("treeTruncated", ui.truncated).put("redacted", hideAll || ui.masks.isNotEmpty())
                .put("display", JSONObject().put("width", width).put("height", height)
                    .put("coordinateSpace", "full-upright-display-normalized-0-to-1"))
                .put("image", JSONObject().put("mimeType", "image/jpeg").put("width", encoded.width).put("height", encoded.height)
                    .put("data", Base64.encodeToString(encoded.bytes, Base64.NO_WRAP)))
                .apply {
                    if (!stable) put("note", "Animation is present. Actions remain available; their target is rechecked against a fresh frame.")
                    if (ui.packageName == ownPackage) put("note", "Connector setup is hidden to protect the access link. Use home to open the phone launcher.")
                    else if (ui.sensitiveFocus) put("note", "Sensitive input is local-only; use back or home to leave it.")
                }
        }
        return error("CAPTURE_UNAVAILABLE")
    }

    suspend fun validate(args: JSONObject): AiActionValidation {
        fun refused(reason: String) = AiActionValidation(reason)
        fun ticketValid() = ledger.valid(args.getString("observationId"), args.getLong("screenVersion"), now())
        if (!ticketValid()) return refused("OBSERVATION_EXPIRED_OR_USED")
        val observed = issuedUi ?: return refused("OBSERVATION_REQUIRED")
        val geometry = display()
        if (geometry.displayWidthPx != width || geometry.displayHeightPx != height) return refused("CAPTURE_GEOMETRY_CHANGED")
        val action = args.getString("action")
        if (action == "tap") snapTapToClickableTarget(args, observed)
        val navigation = action in setOf("home", "back", "recents", "open_app")
        val epoch = ledger.invalidationGeneration
        val ui = uiSnapshot() ?: return refused("DEVICE_LOCKED_OR_ACCESSIBILITY_OFF")
        if (!navigation && (ui.sensitiveFocus || ui.packageName == ownPackage)) return refused("LOCAL_ONLY_SCREEN")
        if (action !in setOf("home", "open_app") && !sameWindow(observed, ui)) return refused("FOREGROUND_CHANGED")
        val scope = if (navigation) null else (actionScope(args, observed) ?: return refused("FOCUSED_FIELD_REQUIRED"))
        if (!navigation && !sameTarget(args, observed, ui)) return refused("TARGET_CHANGED")
        if (!navigation) {
            val fresh = freshFrame()
            if (fresh.rotation != rotation || !geometryMatches(fresh, geometry)) return refused("CAPTURE_GEOMETRY_CHANGED")
            val changed = withContext(Dispatchers.Default) {
                AiVisualFingerprint.materiallyDifferent(lastFingerprint ?: byteArrayOf(),
                    AiVisualFingerprint.sample(fresh.nv21, fresh.width, fresh.height, fresh.rotation), checkNotNull(scope))
            }
            if (changed) return refused("TARGET_CHANGED")
        }
        if (!ticketValid() || epoch != ledger.invalidationGeneration) return refused("OBSERVATION_EXPIRED_OR_USED")
        // Re-read window/target at execution, including after STOP relocation.
        // The deadline bounds canvas races when Accessibility provides no nodes.
        val deadline = now() + 500
        val check = {
            val current = uiSnapshot()
            val currentDisplay = display()
            epoch == ledger.invalidationGeneration && now() <= deadline && current != null &&
                currentDisplay.displayWidthPx == width && currentDisplay.displayHeightPx == height &&
                (action in setOf("home", "open_app") || sameWindow(ui, current)) &&
                (navigation || (!current.sensitiveFocus && current.packageName != ownPackage && sameTarget(args, ui, current)))
        }
        return if (check()) AiActionValidation(stillValid = check) else refused("TARGET_CHANGED")
    }

    private fun snapTapToClickableTarget(args: JSONObject, ui: AiUiSnapshot) {
        val x = args.optDouble("x", Double.NaN)
        val y = args.optDouble("y", Double.NaN)
        if (!x.isFinite() || !y.isFinite() || x !in 0.0..1.0 || y !in 0.0..1.0) return
        if (width <= 0 || height <= 0) return

        // Keep raw coordinate taps as the universal fallback for canvases and
        // custom views. If Accessibility exposes a stable clickable target,
        // center the request inside the smallest enabled target to avoid edges.
        val target = ui.nodes.asSequence()
            .filter { node ->
                node.enabled && node.clickable && node.area > 0L &&
                    node.contains(x * width, y * height)
            }
            .minByOrNull { it.area }
            ?: return

        args.put("x", ((target.left + target.right) / 2.0 / width).coerceIn(0.0, 1.0))
        args.put("y", ((target.top + target.bottom) / 2.0 / height).coerceIn(0.0, 1.0))
    }

    private fun actionScope(args: JSONObject, ui: AiUiSnapshot): AiActionScope? {
        return when (args.getString("action")) {
            "type" -> {
                val field = ui.nodes.singleOrNull { it.focused && it.editable } ?: return null
                AiActionScope((field.left + field.right) / 2.0 / width, (field.top + field.bottom) / 2.0 / height)
            }
            "gesture_path" -> {
                val points = readPath(args) ?: return null
                AiActionScope.path(points)
            }
            "two_finger" -> {
                val first = readPath(
                    args,
                    "firstX", "firstY", "firstToX", "firstToY"
                ) ?: return null
                val second = readPath(
                    args,
                    "secondX", "secondY", "secondToX", "secondToY"
                ) ?: return null
                AiActionScope.paths(listOf(first, second))
            }
            else -> {
                val x = readUnit(args, "x") ?: return null
                val y = readUnit(args, "y") ?: return null
                if (args.getString("action") == "swipe") {
                    val tx = readUnit(args, "toX") ?: return null
                    val ty = readUnit(args, "toY") ?: return null
                    AiActionScope(x, y, tx, ty)
                } else {
                    AiActionScope(x, y)
                }
            }
        }
    }

    private fun readPath(args: JSONObject): List<Pair<Double, Double>>? {
        val array = args.optJSONArray("points") ?: return null
        if (array.length() !in 2..MAX_AI_GESTURE_POINTS) return null
        return buildList(array.length()) {
            for (index in 0 until array.length()) {
                val point = array.optJSONObject(index) ?: return null
                val x = readUnit(point, "x") ?: return null
                val y = readUnit(point, "y") ?: return null
                add(x to y)
            }
        }
    }

    private fun readPath(
        args: JSONObject,
        fromX: String,
        fromY: String,
        toX: String,
        toY: String
    ): List<Pair<Double, Double>>? {
        val x = readUnit(args, fromX) ?: return null
        val y = readUnit(args, fromY) ?: return null
        val tx = readUnit(args, toX) ?: return null
        val ty = readUnit(args, toY) ?: return null
        return listOf(x to y, tx to ty)
    }

    private fun readUnit(source: JSONObject, key: String): Double? {
        val value = source.optDouble(key, Double.NaN)
        return value.takeIf { it.isFinite() && it in 0.0..1.0 }
    }

    private fun sameTarget(args: JSONObject, a: AiUiSnapshot, b: AiUiSnapshot): Boolean {
        if (!sameWindow(a, b) || a.sensitiveFocus != b.sensitiveFocus || a.masks != b.masks) return false
        if (args.getString("action") == "type") {
            val field = a.nodes.singleOrNull { it.focused && it.editable } ?: return false
            return field.enabled && field == b.nodes.singleOrNull { it.focused && it.editable }
        }
        val scope = actionScope(args, a) ?: return false
        if (args.getString("action") in MOTION_ACTIONS) {
            fun relevant(ui: AiUiSnapshot) = ui.nodes.filter {
                it.area < width.toLong() * height / 3 &&
                    scope.contains((it.left + it.right) / 2.0 / width, (it.top + it.bottom) / 2.0 / height)
            }.toSet()
            return relevant(a) == relevant(b)
        }
        fun target(ui: AiUiSnapshot) = ui.nodes.filter {
            it.area < width.toLong() * height / 3 && it.contains(scope.x * width, scope.y * height)
        }.minByOrNull { it.area }
        val target = target(a)
        return target == target(b) && target?.enabled != false
    }

    fun geometry(): Pair<Int, Int> = width to height
    private fun sameWindow(a: AiUiSnapshot, b: AiUiSnapshot) = a.packageName == b.packageName && a.windowId == b.windowId
    private fun samePrivacyContext(a: AiUiSnapshot, b: AiUiSnapshot) = sameWindow(a, b) && a.sensitiveFocus == b.sensitiveFocus && a.masks == b.masks
    private fun geometryMatches(frame: AiRawFrame, profile: CaptureProfile): Boolean {
        val w = if (frame.rotation % 180 == 0) frame.width else frame.height
        val h = if (frame.rotation % 180 == 0) frame.height else frame.width
        return kotlin.math.abs(w.toDouble() / h - profile.displayWidthPx.toDouble() / profile.displayHeightPx) <= 0.015
    }
    private fun error(code: String) = JSONObject().put("error", code).put("applied", false)

    private companion object {
        const val QUIET_WINDOW_MS = 100L
        const val MAX_SETTLE_MS = 220L
        const val SETTLE_POLL_MS = 40L
        const val MAX_AI_GESTURE_POINTS = 32
        val MOTION_ACTIONS = setOf("swipe", "gesture_path", "two_finger")
    }
}
