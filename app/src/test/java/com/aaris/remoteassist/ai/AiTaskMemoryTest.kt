package com.aaris.remoteassist.ai

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class AiTaskMemoryTest {
    @Test fun taskMemoryKeepsGoalFactsAndBoundedTrajectoryWithoutTypedText() {
        val memory = AiTaskMemory()
        val started = memory.start("Fill the admission form")
        assertEquals("running", started.getString("status"))
        memory.update("Complete address section", "Name section already completed")

        repeat(14) { index ->
            memory.recordAction(
                actionId = "action-$index",
                action = if (index == 3) "type" else "tap",
                rawIntent = "Continue section $index",
                rawExpectedOutcome = "Next control becomes visible",
                rawContextNote = if (index == 4) "Category still pending" else null,
                effect = AiActionEffectAnalyzer.classify("tap", true, 0.05),
                applied = true,
                packageName = "forms.app",
                mode = AiInteractionMode.STRICT
            )
        }

        val state = memory.snapshot()
        assertEquals("Fill the admission form", state.getString("goal"))
        assertEquals(14, state.getInt("step"))
        assertEquals(12, state.getJSONArray("recentActions").length())
        assertFalse(state.toString().contains("typed text"))
        assertTrue(state.getJSONArray("facts").toString().contains("Category still pending"))
    }

    @Test fun repeatedNoEffectMarksTaskStalledAndProgressClearsIt() {
        val memory = AiTaskMemory()
        memory.start("Play the current game")
        repeat(2) { index ->
            memory.recordAction(
                "tap-$index", "tap", "Roll dice", "Dice result appears", null,
                AiActionEffectAnalyzer.classify("tap", true, 0.0), true,
                "game.app", AiInteractionMode.DYNAMIC_CANVAS
            )
        }
        assertTrue(memory.snapshot().getBoolean("stalled"))

        memory.recordAction(
            "tap-progress", "tap", "Roll dice", "Dice result appears", null,
            AiActionEffectAnalyzer.classify("tap", true, 0.25), true,
            "game.app", AiInteractionMode.DYNAMIC_CANVAS
        )
        assertFalse(memory.snapshot().getBoolean("stalled"))
    }

    @Test fun classifierSeparatesFormsFromLowSemanticAnimatedCanvas() {
        val field = AiUiNode("name", "EditText", "", 0, 0, 100, 40, true, true, false, true)
        val form = AiUiSnapshot("form", JSONArray(), emptyList(), false, false, 1, listOf(field))
        assertEquals(AiInteractionMode.STRICT, AiInteractionClassifier.classify(form, settled = true))

        val game = AiUiSnapshot("game", JSONArray(), emptyList(), false, false, 2, emptyList())
        assertEquals(AiInteractionMode.DYNAMIC_CANVAS, AiInteractionClassifier.classify(game, settled = false))
    }

    @Test fun effectAnalyzerDistinguishesNoLocalAndMajorChanges() {
        assertEquals("no_visible_effect", AiActionEffectAnalyzer.classify("tap", true, 0.001).kind)
        assertEquals("local_change", AiActionEffectAnalyzer.classify("tap", true, 0.08).kind)
        assertEquals("major_change", AiActionEffectAnalyzer.classify("tap", true, 0.50).kind)
        assertEquals("not_applied", AiActionEffectAnalyzer.classify("tap", false, 0.50).kind)
    }

    @Test fun backgroundMotionDoesNotMasqueradeAsTargetProgressAndFailuresAreRemembered() {
        val backgroundOnly = AiActionEffectAnalyzer.classify(
            action = "tap",
            applied = true,
            changeRatio = 0.35,
            targetChangeRatio = 0.002
        )
        assertEquals("background_motion_only", backgroundOnly.kind)
        assertEquals(0.002, backgroundOnly.toJson().getDouble("targetChangeRatio"), 0.0001)

        val memory = AiTaskMemory()
        memory.start("Complete a multi-step task")
        memory.recordAction(
            actionId = "stale-1",
            action = "tap",
            rawIntent = "Continue",
            rawExpectedOutcome = "Next screen",
            rawContextNote = null,
            effect = AiActionEffectAnalyzer.classify("tap", false, null, null),
            applied = false,
            packageName = "app",
            mode = AiInteractionMode.INTERACTIVE,
            resultCode = "TARGET_CHANGED"
        )
        val recent = memory.snapshot().getJSONArray("recentActions").getJSONObject(0)
        assertEquals("TARGET_CHANGED", recent.getString("resultCode"))
        assertEquals("not_applied", recent.getJSONObject("effect").getString("kind"))
    }
}
