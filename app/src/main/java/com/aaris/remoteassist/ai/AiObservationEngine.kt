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
import java.security.MessageDigest
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
    private var lastDeliveredVisualDigest: ByteArray? = null
    private var lastDeliveredVisualObservationId: String? = null
    private var lastDeliveredVisualUi: AiUiSnapshot? = null
    private var lastDeliveredVisualFrameWidth = 0
    private var lastDeliveredVisualFrameHeight = 0
    private var lastDeliveredVisualRotation = 0
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
            if (quietFor >= QUIET_WINDOW_MS || elapsed >= MAX_ANIMATED_SETTLE_MS) return

            val remainingQuiet = (QUIET_WINDOW_MS - quietFor).coerceAtLeast(1L)
            val remainingBudget = (MAX_ANIMATED_SETTLE_MS - elapsed).coerceAtLeast(1L)
            pause(minOf(SETTLE_POLL_MS, remainingQuiet, remainingBudget))
        }
    }

    suspend fun observe(detail: Boolean = false, preferSemantic: Boolean = false): JSONObject {
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
            /*
             * Fingerprinting is the safety primitive and remains mandatory even
             * when a semantic observation can omit JPEG pixels. This keeps
             * target validation bound to the exact captured frame while avoiding
             * JPEG encode/Base64/network work on stable native Android screens.
             */
            val (fingerprint, visualDigest) = withContext(Dispatchers.Default) {
                AiVisualFingerprint.sample(
                    frame.nv21,
                    frame.width,
                    frame.height,
                    frame.rotation
                ) to MessageDigest.getInstance("SHA-256").digest(frame.nv21)
            }
            val after = uiSnapshot() ?: return error("DEVICE_LOCKED_OR_ACCESSIBILITY_OFF")
            if (epoch != ledger.invalidationGeneration) return error("OBSERVATION_INVALIDATED")
            if (!samePrivacyContext(ui, after)) {
                if (attempt == 0) return@repeat
                return error("SCREEN_CHANGING")
            }

            val hints = if (hideAll) JSONArray() else publishedHints(ui)
            val stableBeforeEncode = revision == ledger.eventRevision
            val semanticOnly =
                preferSemantic &&
                    (
                        (hideAll && hints.length() == 0) ||
                            (
                                stableBeforeEncode &&
                                    !ui.truncated &&
                                    hasActionableHint(hints)
                                )
                        )
            /*
             * Successful actions ask for a semantic-first follow-up. Canvas and
             * game screens normally still need pixels, but retransmitting an
             * exactly unchanged sampled frame only burns JPEG/vision tokens.
             * Reuse is deliberately stricter than action validation: exact
             * fingerprint equality, stable event revision, same privacy context,
             * and never for an explicit detail request. Any visual change falls
             * straight back to a fresh JPEG.
             */
            val reusableVisualObservationId =
                if (
                    preferSemantic &&
                    !detail &&
                    !semanticOnly &&
                    stableBeforeEncode &&
                    !ui.truncated &&
                    lastDeliveredVisualFrameWidth == frame.width &&
                    lastDeliveredVisualFrameHeight == frame.height &&
                    lastDeliveredVisualRotation == frame.rotation &&
                    lastDeliveredVisualDigest?.contentEquals(visualDigest) == true &&
                    lastDeliveredVisualUi?.let { samePrivacyContext(it, ui) } == true
                ) {
                    lastDeliveredVisualObservationId
                } else {
                    null
                }

            val encoded =
                if (semanticOnly || reusableVisualObservationId != null) {
                    null
                } else {
                    val value =
                        withContext(Dispatchers.Default) {
                            encodeFrame(
                                frame,
                                if (detail) 2400 else 1280,
                                ui.masks,
                                geometry.displayWidthPx,
                                geometry.displayHeightPx,
                                hideAll
                            )
                        }
                    /*
                     * Encoding can take long enough for the foreground window
                     * or privacy masks to change. Recheck before publishing
                     * any bytes; a stale encoded frame is discarded rather
                     * than risking an unmasked visual result.
                     */
                    val afterEncoding =
                        uiSnapshot()
                            ?: return error("DEVICE_LOCKED_OR_ACCESSIBILITY_OFF")
                    if (epoch != ledger.invalidationGeneration) {
                        return error("OBSERVATION_INVALIDATED")
                    }
                    if (!samePrivacyContext(ui, afterEncoding)) {
                        if (attempt == 0) return@repeat
                        return error("SCREEN_CHANGING")
                    }
                    value
                }

            val stable = revision == ledger.eventRevision
            val id = UUID.randomUUID().toString()
            width = geometry.displayWidthPx; height = geometry.displayHeightPx; rotation = frame.rotation
            issuedUi = ui; lastFingerprint = fingerprint
            if (encoded != null) {
                lastDeliveredVisualDigest = visualDigest.copyOf()
                lastDeliveredVisualObservationId = id
                lastDeliveredVisualUi = ui
                lastDeliveredVisualFrameWidth = frame.width
                lastDeliveredVisualFrameHeight = frame.height
                lastDeliveredVisualRotation = frame.rotation
            }
            ledger.issue(id, now())
            return JSONObject().put("observationId", id).put("screenVersion", ledger.version)
                .put("capturedAtElapsedMs", frame.receivedAtMs).put("settled", stable)
                .put("currentPackage", ui.packageName).put("uiHints", hints)
                .put("treeTruncated", ui.truncated).put("redacted", hideAll || ui.masks.isNotEmpty())
                .put("display", JSONObject().put("width", width).put("height", height)
                    .put("coordinateSpace", "full-upright-display-normalized-0-to-1"))
                .apply {
                    if (encoded != null) {
                        put(
                            "image",
                            JSONObject()
                                .put("mimeType", "image/jpeg")
                                .put("width", encoded.width)
                                .put("height", encoded.height)
                                .put(
                                    "data",
                                    Base64.encodeToString(
                                        encoded.bytes,
                                        Base64.NO_WRAP
                                    )
                                )
                        )
                    } else if (semanticOnly) {
                        put("visualDelivery", "semantic-only")
                        put("imageEncodingSkipped", true)
                    } else {
                        put("visualDelivery", "reused")
                        put("imageEncodingSkipped", true)
                        put(
                            "sameVisualAsObservationId",
                            checkNotNull(reusableVisualObservationId)
                        )
                    }
                    if (!stable) put("note", "Animation is present. Actions remain available; their target is rechecked against a fresh frame.")
                    if (ui.packageName == ownPackage) put("note", "Connector setup is hidden to protect the access link. Use home to open the phone launcher.")
                    else if (ui.sensitiveFocus) put("note", "Sensitive input is local-only; use back or home to leave it.")
                }
        }
        return error("CAPTURE_UNAVAILABLE")
    }

    /**
     * Enrich compact hints with Accessibility-proven motor state while keeping
     * screenshots primary. Stable resource ids are published only when unique,
     * enabled and actionable. Editable fields count as actionable even when an
     * OEM reports clickable=false: a semantic target lets the model focus the
     * field precisely before the separate validated type action.
     *
     * Raw ids are never synthesized from text, and duplicate resource ids
     * (common in lists) are intentionally withheld so the model cannot target a
     * repeated row by accident. Older clients can ignore the optional fields.
     */
    private fun hasActionableHint(hints: JSONArray): Boolean {
        for (index in 0 until hints.length()) {
            val hint = hints.optJSONObject(index) ?: continue
            if (
                hint.optBoolean("clickable", false) ||
                hint.optBoolean("editable", false) ||
                hint.optString("targetId", "").isNotBlank()
            ) {
                return true
            }
        }
        return false
    }

    private fun publishedHints(ui: AiUiSnapshot): JSONArray {
        if (ui.hints.length() == 0 || ui.nodes.isEmpty()) return ui.hints

        val idCounts = ui.nodes.asSequence()
            .map { it.id }
            .filter { it.isNotBlank() && it.length <= MAX_TARGET_ID_CHARS }
            .groupingBy { it }
            .eachCount()
        val semanticTargets = ui.nodes.filter { node ->
            node.enabled && (node.clickable || node.editable) && node.area > 0L &&
                node.id.isNotBlank() && node.id.length <= MAX_TARGET_ID_CHARS &&
                idCounts[node.id] == 1
        }

        val result = JSONArray()
        for (index in 0 until ui.hints.length()) {
            val original = ui.hints.optJSONObject(index)
            if (original == null) {
                result.put(ui.hints.opt(index))
                continue
            }
            val hint = JSONObject(original.toString())
            val bounds = original.optJSONArray("bounds")
            if (bounds != null && bounds.length() == 4) {
                val matchingNodes = ui.nodes.filter { node ->
                    node.left == bounds.optInt(0, Int.MIN_VALUE) &&
                        node.top == bounds.optInt(1, Int.MIN_VALUE) &&
                        node.right == bounds.optInt(2, Int.MIN_VALUE) &&
                        node.bottom == bounds.optInt(3, Int.MIN_VALUE)
                }
                val stateNode = matchingNodes.minByOrNull { node -> node.area }
                stateNode?.let { node ->
                    hint.put("enabled", node.enabled)
                    hint.put("focused", node.focused)
                }

                if (
                    original.optBoolean("clickable", false) ||
                    original.optBoolean("editable", false)
                ) {
                    val target = semanticTargets.singleOrNull { node ->
                        node.left == bounds.optInt(0, Int.MIN_VALUE) &&
                            node.top == bounds.optInt(1, Int.MIN_VALUE) &&
                            node.right == bounds.optInt(2, Int.MIN_VALUE) &&
                            node.bottom == bounds.optInt(3, Int.MIN_VALUE)
                    }
                    target?.let { hint.put("targetId", it.id) }
                }
            }
            result.put(hint)
        }
        return result
    }

    suspend fun validate(args: JSONObject): AiActionValidation {
        fun refused(reason: String) = AiActionValidation(reason)
        fun ticketValid() = ledger.valid(args.getString("observationId"), args.getLong("screenVersion"), now())
        if (!ticketValid()) return refused("OBSERVATION_EXPIRED_OR_USED")
        val observed = issuedUi ?: return refused("OBSERVATION_REQUIRED")
        val geometry = display()
        if (geometry.displayWidthPx != width || geometry.displayHeightPx != height) return refused("CAPTURE_GEOMETRY_CHANGED")
        val action = args.getString("action")
        if (action == "tap" && !snapTapToClickableTarget(args, observed)) return refused("TARGET_CHANGED")
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

    private fun snapTapToClickableTarget(args: JSONObject, ui: AiUiSnapshot): Boolean {
        val requestedTarget = args.optString("targetId", "").trim()
        if (args.has("targetId")) {
            if (requestedTarget.isEmpty() || requestedTarget.length > MAX_TARGET_ID_CHARS) return false
            val exact = ui.nodes.filter { node ->
                node.id == requestedTarget && node.enabled &&
                    (node.clickable || node.editable) && node.area > 0L
            }
            // Fail closed instead of guessing when an id is stale or repeated.
            if (exact.size != 1) return false
            centerTap(args, exact.single())
            return true
        }

        val x = args.optDouble("x", Double.NaN)
        val y = args.optDouble("y", Double.NaN)
        if (!x.isFinite() || !y.isFinite() || x !in 0.0..1.0 || y !in 0.0..1.0) return false
        if (width <= 0 || height <= 0) return false

        val tapX = x * width
        val tapY = y * height
        val clickable = ui.nodes.asSequence()
            .filter { node -> node.enabled && node.clickable && node.area > 0L }
            .toList()

        // Keep raw coordinate taps as the universal fallback for canvases and
        // custom views. If Accessibility exposes a stable clickable target that
        // already contains the request, center inside the smallest enabled node.
        val direct = clickable.asSequence()
            .filter { node -> node.contains(tapX, tapY) }
            .minByOrNull { it.area }
        if (direct != null) {
            centerTap(args, direct)
            return true
        }

        /*
         * Vision models occasionally land a few pixels outside a small icon or
         * button edge. Treat that as pointer imprecision, not as a reason to
         * click arbitrary nearby UI: auto-aim only when exactly one reasonably
         * sized clickable node falls inside a narrow normalized halo. If two
         * controls are close together we deliberately keep the raw coordinate
         * so the fresh-pixel/semantic validation can fail closed instead of
         * guessing which control the model meant.
         */
        val displayArea = width.toLong() * height.toLong()
        val nearby = clickable.filter { node ->
            node.area <= displayArea / 3L &&
                normalizedDistanceSquaredToNode(x, y, node) <= TAP_NEAR_MISS_RADIUS_SQ
        }
        if (nearby.size == 1) {
            centerTap(args, nearby.single())
        }
        return true
    }

    private fun centerTap(args: JSONObject, node: AiUiNode) {
        args.put("x", ((node.left + node.right) / 2.0 / width).coerceIn(0.0, 1.0))
        args.put("y", ((node.top + node.bottom) / 2.0 / height).coerceIn(0.0, 1.0))
    }

    private fun normalizedDistanceSquaredToNode(
        x: Double,
        y: Double,
        node: AiUiNode
    ): Double {
        val left = node.left.toDouble() / width
        val right = node.right.toDouble() / width
        val top = node.top.toDouble() / height
        val bottom = node.bottom.toDouble() / height
        val dx = when {
            x < left -> left - x
            x > right -> x - right
            else -> 0.0
        }
        val dy = when {
            y < top -> top - y
            y > bottom -> y - bottom
            else -> 0.0
        }
        return dx * dx + dy * dy
    }

    private fun actionScope(args: JSONObject, ui: AiUiSnapshot): AiActionScope? {
        return when (args.getString("action")) {
            "type" -> {
                val field = ui.nodes.singleOrNull { it.focused && it.editable } ?: return null
                AiActionScope((field.left + field.right) / 2.0 / width, (field.top + field.bottom) / 2.0 / height)
            }
            "drag" -> AiActionScope.fromPath(dragPoints(args))
            "two_finger" -> AiActionScope.fromPaths(twoFingerPaths(args))
            else -> {
                val x = args.getDouble("x")
                val y = args.getDouble("y")
                val swipe = args.getString("action") == "swipe"
                val tx = if (swipe) args.getDouble("toX") else x
                val ty = if (swipe) args.getDouble("toY") else y
                require(listOf(x, y, tx, ty).all { it.isFinite() && it in 0.0..1.0 })
                AiActionScope(x, y, tx, ty)
            }
        }
    }

    private fun dragPoints(args: JSONObject): List<Pair<Double, Double>> {
        val points = args.getJSONArray("points")
        require(points.length() in 2..MAX_AI_DRAG_POINTS)
        return List(points.length()) { index ->
            val point = points.getJSONObject(index)
            require(point.length() == 2 && point.has("x") && point.has("y"))
            val x = point.getDouble("x")
            val y = point.getDouble("y")
            require(x.isFinite() && y.isFinite() && x in 0.0..1.0 && y in 0.0..1.0)
            x to y
        }
    }

    private fun twoFingerPaths(args: JSONObject): List<List<Pair<Double, Double>>> {
        fun point(xKey: String, yKey: String): Pair<Double, Double> {
            val x = args.getDouble(xKey)
            val y = args.getDouble(yKey)
            require(x.isFinite() && y.isFinite() && x in 0.0..1.0 && y in 0.0..1.0)
            return x to y
        }
        return listOf(
            listOf(point("x", "y"), point("toX", "toY")),
            listOf(point("secondX", "secondY"), point("secondToX", "secondToY"))
        )
    }

    private fun sameTarget(args: JSONObject, a: AiUiSnapshot, b: AiUiSnapshot): Boolean {
        if (!sameWindow(a, b) || a.sensitiveFocus != b.sensitiveFocus || a.masks != b.masks) return false
        if (args.getString("action") == "type") {
            val field = a.nodes.singleOrNull { it.focused && it.editable } ?: return false
            return field.enabled && field == b.nodes.singleOrNull { it.focused && it.editable }
        }
        val scope = actionScope(args, a) ?: return false
        if (args.getString("action") in setOf("swipe", "drag", "two_finger")) {
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

    companion object {
        private const val MAX_AI_DRAG_POINTS = 24
        private const val MAX_TARGET_ID_CHARS = 256
        private const val QUIET_WINDOW_MS = 100L
        private const val MAX_ANIMATED_SETTLE_MS = 220L
        private const val SETTLE_POLL_MS = 40L
        private const val TAP_NEAR_MISS_RADIUS = 0.035
        private const val TAP_NEAR_MISS_RADIUS_SQ = TAP_NEAR_MISS_RADIUS * TAP_NEAR_MISS_RADIUS
    }
}
