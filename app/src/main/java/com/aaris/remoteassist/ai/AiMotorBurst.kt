package com.aaris.remoteassist.ai

import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject

data class AiMotorBurstGuard(
    val packageName: String,
    val windowId: Int,
    val displayWidthPx: Int,
    val displayHeightPx: Int,
    val rotation: Int
)

data class AiMotorBurstCheckpoint(
    val safe: Boolean,
    val reason: String,
    val changeRatio: Double? = null,
    val fingerprint: ByteArray? = null
)

/**
 * Defense-in-depth policy for model-generated short motor programs.
 *
 * A burst is deliberately small and touch-only: it is not a general script
 * engine. It exists to remove cloud round-trips between a few tightly coupled
 * motor actions while preserving a fresh visual checkpoint afterwards.
 */
object AiMotorBurstPolicy {
    private val allowed = setOf("tap", "long_press", "swipe", "drag", "two_finger")

    fun parseSteps(raw: JSONArray): List<JSONObject> {
        require(raw.length() in 1..MAX_STEPS) { "BURST_STEP_COUNT" }
        val result = List(raw.length()) { index ->
            val step = JSONObject(raw.getJSONObject(index).toString())
            require(step.optString("action") in allowed) { "BURST_ACTION_NOT_ALLOWED" }
            val afterMs = step.optInt("afterMs", 0)
            require(afterMs in 0..MAX_AFTER_MS) { "BURST_DELAY" }
            validateCoordinates(step)
            validateDuration(step)
            step
        }
        require(result.sumOf(::estimatedStepBudgetMs) <= MAX_TOTAL_BUDGET_MS) {
            "BURST_TOO_LONG"
        }
        return result
    }

    fun estimatedStepBudgetMs(step: JSONObject): Int {
        val action = step.getString("action")
        val duration = when (action) {
            "tap" -> 80
            "long_press" -> step.optInt("durationMs", 500)
            "swipe", "drag", "two_finger" -> step.optInt("durationMs", 240)
            else -> error("BURST_ACTION_NOT_ALLOWED")
        }
        return duration + step.optInt("afterMs", 0)
    }

    private fun validateDuration(step: JSONObject) {
        if (!step.has("durationMs")) return
        val duration = step.getInt("durationMs")
        val action = step.getString("action")
        val valid = when (action) {
            "tap" -> false
            "long_press" -> duration in 450..700
            "swipe", "drag", "two_finger" -> duration in 80..700
            else -> false
        }
        require(valid) { "BURST_DURATION" }
    }

    private fun validateCoordinates(step: JSONObject) {
        fun unit(key: String): Double {
            val value = step.getDouble(key)
            require(value.isFinite() && value in 0.0..1.0) { "BURST_COORDINATE" }
            return value
        }
        when (step.getString("action")) {
            "tap", "long_press" -> {
                unit("x"); unit("y")
            }
            "swipe" -> {
                unit("x"); unit("y"); unit("toX"); unit("toY")
            }
            "drag" -> {
                val points = step.getJSONArray("points")
                require(points.length() in 2..MAX_DRAG_POINTS) { "BURST_DRAG_POINTS" }
                repeat(points.length()) { index ->
                    val point = points.getJSONObject(index)
                    require(point.length() == 2) { "BURST_DRAG_POINT_SHAPE" }
                    val x = point.getDouble("x")
                    val y = point.getDouble("y")
                    require(x.isFinite() && y.isFinite() && x in 0.0..1.0 && y in 0.0..1.0) {
                        "BURST_COORDINATE"
                    }
                }
            }
            "two_finger" -> {
                listOf(
                    "x", "y", "toX", "toY",
                    "secondX", "secondY", "secondToX", "secondToY"
                ).forEach(::unit)
            }
        }
    }

    const val MAX_STEPS = 4
    const val MAX_AFTER_MS = 300
    const val MAX_TOTAL_BUDGET_MS = 1_800
    private const val MAX_DRAG_POINTS = 24
}

class AiMotorBurstMonitor(
    private val ownPackage: String,
    private val freshFrame: suspend () -> AiRawFrame,
    private val display: () -> CaptureProfile,
    private val uiSnapshot: () -> AiUiSnapshot?,
    private val pause: suspend (Long) -> Unit = { delay(it) }
) {
    fun environmentMatches(guard: AiMotorBurstGuard): Boolean {
        val profile = display()
        val ui = uiSnapshot() ?: return false
        return profile.displayWidthPx == guard.displayWidthPx &&
            profile.displayHeightPx == guard.displayHeightPx &&
            !ui.sensitiveFocus &&
            ui.packageName != ownPackage &&
            ui.packageName == guard.packageName &&
            ui.windowId == guard.windowId
    }

    suspend fun checkpoint(
        guard: AiMotorBurstGuard,
        previousFingerprint: ByteArray,
        afterMs: Int
    ): AiMotorBurstCheckpoint {
        if (afterMs > 0) pause(afterMs.toLong())
        if (!environmentMatches(guard)) {
            return AiMotorBurstCheckpoint(false, "BURST_ENVIRONMENT_CHANGED")
        }
        val profile = display()
        val frame = freshFrame()
        if (frame.rotation != guard.rotation) {
            return AiMotorBurstCheckpoint(false, "CAPTURE_GEOMETRY_CHANGED")
        }
        val uprightWidth = if (frame.rotation % 180 == 0) frame.width else frame.height
        val uprightHeight = if (frame.rotation % 180 == 0) frame.height else frame.width
        if (kotlin.math.abs(
                uprightWidth.toDouble() / uprightHeight -
                    profile.displayWidthPx.toDouble() / profile.displayHeightPx
            ) > 0.015) {
            return AiMotorBurstCheckpoint(false, "CAPTURE_GEOMETRY_CHANGED")
        }
        val fingerprint = AiVisualFingerprint.sample(
            frame.nv21,
            frame.width,
            frame.height,
            frame.rotation
        )
        val ratio = AiVisualFingerprint.differenceRatio(previousFingerprint, fingerprint)
        if (ratio == null || ratio > MAX_SCENE_CHANGE_RATIO) {
            return AiMotorBurstCheckpoint(false, "BURST_SCENE_CHANGED", ratio, fingerprint)
        }
        return AiMotorBurstCheckpoint(true, "BURST_CONTINUE", ratio, fingerprint)
    }

    companion object {
        private const val MAX_SCENE_CHANGE_RATIO = 0.52
    }
}
