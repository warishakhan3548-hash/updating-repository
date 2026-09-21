package com.aaris.shield.visual

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VisualSafetyEngineTest {
    @Test
    fun keepsOnlyOnePendingFrameAndReplacesStaleWork() {
        val enteredFirst = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val completed = CountDownLatch(2)
        val seenWidths = Collections.synchronizedList(mutableListOf<Int>())

        val classifier = object : VisualSafetyClassifier {
            override val modelId = "fake"
            override var lifecycle = VisualModelLifecycle.READY
                private set

            override fun initialize() = lifecycle

            override fun classify(frame: VisualFrame): VisualClassifierOutcome {
                seenWidths += frame.width
                if (frame.width == 1) {
                    enteredFirst.countDown()
                    releaseFirst.await(2, TimeUnit.SECONDS)
                }
                return VisualClassifierOutcome.Success(
                    VisualModelScores(0.9f, 0.1f),
                    inferenceMillis = 1L,
                )
            }

            override fun close() {
                lifecycle = VisualModelLifecycle.CLOSED
            }
        }

        val engine = VisualSafetyEngine(
            classifier = classifier,
            limiter = AdaptiveInferenceLimiter(minimumIntervalMillis = 0L),
        )
        fun frame(width: Int) = VisualFrame.fromArgb(width, 1, IntArray(width))
        val callback: (VisualSafetyResult) -> Unit = { completed.countDown() }

        assertEquals(VisualSubmission.ACCEPTED, engine.submit(frame(1), callback))
        assertTrue(enteredFirst.await(1, TimeUnit.SECONDS))
        assertEquals(VisualSubmission.ACCEPTED, engine.submit(frame(2), callback))
        assertEquals(
            VisualSubmission.REPLACED_OLDER_PENDING_FRAME,
            engine.submit(frame(3), callback),
        )
        releaseFirst.countDown()
        assertTrue(completed.await(2, TimeUnit.SECONDS))
        assertEquals(listOf(1, 3), seenWidths.toList())
        engine.close()
    }
}
