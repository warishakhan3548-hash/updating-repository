package com.aaris.remoteassist.ai

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

enum class AiInteractionMode(val wireName: String) {
    STRICT("strict"),
    INTERACTIVE("interactive"),
    DYNAMIC_CANVAS("dynamic_canvas")
}

data class AiActionEffect(
    val kind: String,
    /** Whole-screen visual change; retained as changeRatio for wire compatibility. */
    val changeRatio: Double?,
    /** Change around the intended touch/field path when one exists. */
    val targetChangeRatio: Double? = null,
    val confidence: String = "visual_only"
) {
    fun toJson() = JSONObject()
        .put("kind", kind)
        .put("confidence", confidence)
        .apply {
            changeRatio?.let { put("changeRatio", it) }
            targetChangeRatio?.let { put("targetChangeRatio", it) }
        }
}

object AiActionEffectAnalyzer {
    fun classify(
        action: String,
        applied: Boolean?,
        changeRatio: Double?,
        targetChangeRatio: Double? = null
    ): AiActionEffect {
        if (applied != true) return AiActionEffect("not_applied", changeRatio, targetChangeRatio)
        if (changeRatio == null || !changeRatio.isFinite()) return AiActionEffect("unknown", null, targetChangeRatio)

        val local = targetChangeRatio?.takeIf { it.isFinite() }
        if (local != null && action !in setOf("home", "back", "recents", "open_app")) {
            return when {
                local < NO_EFFECT_RATIO && changeRatio >= BACKGROUND_MOTION_RATIO ->
                    AiActionEffect("background_motion_only", changeRatio, local)
                local < NO_EFFECT_RATIO ->
                    AiActionEffect("no_visible_effect", changeRatio, local)
                changeRatio >= MAJOR_CHANGE_RATIO ->
                    AiActionEffect("major_change", changeRatio, local)
                local < LOCAL_CHANGE_RATIO ->
                    AiActionEffect("local_change", changeRatio, local)
                else ->
                    AiActionEffect("target_change", changeRatio, local)
            }
        }

        return when {
            action == "wait" && changeRatio < NO_EFFECT_RATIO -> AiActionEffect("waited_stable", changeRatio)
            changeRatio < NO_EFFECT_RATIO -> AiActionEffect("no_visible_effect", changeRatio)
            changeRatio < LOCAL_CHANGE_RATIO -> AiActionEffect("local_change", changeRatio)
            else -> AiActionEffect("major_change", changeRatio)
        }
    }

    private const val NO_EFFECT_RATIO = 0.012
    private const val BACKGROUND_MOTION_RATIO = 0.04
    private const val LOCAL_CHANGE_RATIO = 0.18
    private const val MAJOR_CHANGE_RATIO = 0.42
}

/**
 * Bounded, run-local semantic memory for the phone agent.
 *
 * It deliberately stores no screenshots and never records typed text. The model
 * can keep a compact goal/subgoal/fact summary here so a long UI task can recover
 * from ads, animations, transient tool failures or context compaction without
 * replaying raw form values.
 */
class AiTaskMemory {
    private var taskId: String? = null
    private var goal = ""
    private var subgoal = ""
    private var status = "idle"
    private var step = 0
    private var noProgressStreak = 0
    private val facts = ArrayDeque<String>()
    private val recent = ArrayDeque<JSONObject>()

    fun start(rawGoal: String): JSONObject {
        val cleanGoal = bounded(rawGoal, MAX_GOAL_CHARS)
        require(cleanGoal.isNotEmpty())
        if (taskId != null && status == "running" && goal == cleanGoal) return snapshot()
        taskId = UUID.randomUUID().toString()
        goal = cleanGoal
        subgoal = ""
        status = "running"
        step = 0
        noProgressStreak = 0
        facts.clear()
        recent.clear()
        return snapshot()
    }

    fun update(rawSubgoal: String? = null, rawFact: String? = null): JSONObject {
        rawSubgoal?.let {
            subgoal = bounded(it, MAX_NOTE_CHARS)
        }
        rawFact?.let {
            val fact = bounded(it, MAX_NOTE_CHARS)
            if (fact.isNotEmpty() && fact !in facts) {
                facts.addLast(fact)
                while (facts.size > MAX_FACTS) facts.removeFirst()
            }
        }
        return snapshot()
    }

    fun finish(rawSummary: String? = null): JSONObject {
        rawSummary?.let { update(rawFact = it) }
        status = if (taskId == null) "idle" else "completed"
        return snapshot()
    }

    fun clear() {
        taskId = null
        goal = ""
        subgoal = ""
        status = "idle"
        step = 0
        noProgressStreak = 0
        facts.clear()
        recent.clear()
    }

    fun recordAction(
        actionId: String,
        action: String,
        rawIntent: String?,
        rawExpectedOutcome: String?,
        rawContextNote: String?,
        effect: AiActionEffect,
        applied: Boolean?,
        packageName: String?,
        mode: AiInteractionMode,
        resultCode: String? = null
    ): JSONObject {
        if (taskId == null) {
            // A client that predates phone_task_start still gets useful bounded
            // trajectory memory without inventing a user goal.
            taskId = UUID.randomUUID().toString()
            status = "running"
        }
        val intent = bounded(rawIntent.orEmpty(), MAX_NOTE_CHARS)
        val expected = bounded(rawExpectedOutcome.orEmpty(), MAX_NOTE_CHARS)
        if (intent.isNotEmpty()) subgoal = intent
        rawContextNote?.let { update(rawFact = it) }

        step++
        if (action != "wait") {
            noProgressStreak = when (effect.kind) {
                "no_visible_effect", "background_motion_only", "not_applied", "unknown" ->
                    (noProgressStreak + 1).coerceAtMost(99)
                else -> 0
            }
        } else if (effect.kind == "major_change" || effect.kind == "local_change") {
            noProgressStreak = 0
        }

        val entry = JSONObject()
            .put("step", step)
            .put("actionId", actionId)
            .put("action", action)
            .put("applied", applied ?: JSONObject.NULL)
            .put("effect", effect.toJson())
            .put("interactionMode", mode.wireName)
            .apply {
                if (intent.isNotEmpty()) put("intent", intent)
                if (expected.isNotEmpty()) put("expectedOutcome", expected)
                if (!packageName.isNullOrBlank()) put("package", bounded(packageName, MAX_PACKAGE_CHARS))
                if (!resultCode.isNullOrBlank()) put("resultCode", bounded(resultCode, MAX_RESULT_CODE_CHARS))
            }
        recent.addLast(entry)
        while (recent.size > MAX_RECENT_ACTIONS) recent.removeFirst()
        return snapshot()
    }

    fun snapshot(): JSONObject {
        val recentArray = JSONArray()
        recent.forEach { recentArray.put(JSONObject(it.toString())) }
        val factArray = JSONArray()
        facts.forEach(factArray::put)
        return JSONObject()
            .put("taskId", taskId ?: JSONObject.NULL)
            .put("status", status)
            .put("goal", goal)
            .put("subgoal", subgoal)
            .put("step", step)
            .put("stalled", noProgressStreak >= STALL_THRESHOLD)
            .put("noProgressStreak", noProgressStreak)
            .put("facts", factArray)
            .put("recentActions", recentArray)
    }

    private fun bounded(value: String, maxChars: Int): String =
        value.trim().replace(Regex("\\s+"), " ").take(maxChars)

    companion object {
        private const val MAX_GOAL_CHARS = 800
        private const val MAX_NOTE_CHARS = 320
        private const val MAX_PACKAGE_CHARS = 180
        private const val MAX_RESULT_CODE_CHARS = 96
        private const val MAX_FACTS = 8
        private const val MAX_RECENT_ACTIONS = 12
        private const val STALL_THRESHOLD = 2
    }
}

object AiInteractionClassifier {
    fun classify(
        ui: AiUiSnapshot,
        settled: Boolean,
        displayWidthPx: Int = 0,
        displayHeightPx: Int = 0
    ): AiInteractionMode {
        val actionable = ui.nodes.filter { it.enabled && (it.clickable || it.editable) }
        val enabledActionable = actionable.size
        val hasEditable = actionable.any { it.editable }
        if (hasEditable) return AiInteractionMode.STRICT

        /*
         * Canvas/OpenGL/custom-rendered UIs commonly expose either no useful
         * Accessibility semantics or one giant clickable surface. A settled
         * game board with one full-screen node is still a dynamic canvas; treating
         * it as ordinary semantic UI makes animation around a dice/piece reject a
         * perfectly valid coordinate tap and can also invite container snapping.
         */
        val displayArea =
            displayWidthPx.toLong().coerceAtLeast(0L) *
                displayHeightPx.toLong().coerceAtLeast(0L)
        val broadSurfaceOnly =
            displayArea > 0L &&
                ui.nodes.size <= 4 &&
                actionable.isNotEmpty() &&
                actionable.all { node -> node.area >= displayArea / 3L }

        if (
            (!settled && enabledActionable <= 2) ||
            (ui.nodes.size <= 2 && enabledActionable == 0) ||
            broadSurfaceOnly
        ) {
            return AiInteractionMode.DYNAMIC_CANVAS
        }
        return AiInteractionMode.INTERACTIVE
    }
}
