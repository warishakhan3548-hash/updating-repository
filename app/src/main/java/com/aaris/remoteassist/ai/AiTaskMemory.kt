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
    val changeRatio: Double?,
    val confidence: String = "visual_only"
) {
    fun toJson() = JSONObject()
        .put("kind", kind)
        .put("confidence", confidence)
        .apply { changeRatio?.let { put("changeRatio", it) } }
}

object AiActionEffectAnalyzer {
    fun classify(action: String, applied: Boolean?, changeRatio: Double?): AiActionEffect {
        if (applied != true) return AiActionEffect("not_applied", changeRatio)
        if (changeRatio == null || !changeRatio.isFinite()) return AiActionEffect("unknown", null)
        return when {
            action == "wait" && changeRatio < 0.012 -> AiActionEffect("waited_stable", changeRatio)
            changeRatio < 0.012 -> AiActionEffect("no_visible_effect", changeRatio)
            changeRatio < 0.18 -> AiActionEffect("local_change", changeRatio)
            else -> AiActionEffect("major_change", changeRatio)
        }
    }
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
        mode: AiInteractionMode
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
                "no_visible_effect", "not_applied", "unknown" -> (noProgressStreak + 1).coerceAtMost(99)
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
        private const val MAX_FACTS = 8
        private const val MAX_RECENT_ACTIONS = 12
        private const val STALL_THRESHOLD = 2
    }
}

object AiInteractionClassifier {
    fun classify(ui: AiUiSnapshot, settled: Boolean): AiInteractionMode {
        val enabledActionable = ui.nodes.count { it.enabled && (it.clickable || it.editable) }
        val hasEditable = ui.nodes.any { it.enabled && it.editable }
        if (hasEditable) return AiInteractionMode.STRICT

        // Canvas/OpenGL/custom-rendered UIs commonly expose almost no useful
        // Accessibility semantics. Treat an animating low-semantics screen as a
        // dynamic surface so target-local animation does not invalidate every
        // otherwise safe gesture.
        if ((!settled && enabledActionable <= 2) || (ui.nodes.size <= 2 && enabledActionable == 0)) {
            return AiInteractionMode.DYNAMIC_CANVAS
        }
        return AiInteractionMode.INTERACTIVE
    }
}
