package com.aaris.shield.visual

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Runs one classifier invocation at a time with at most one pending frame.
 * A newer pending frame replaces an older pending frame instead of allowing an
 * unbounded frame queue. In-flight native inference is intentionally not
 * interrupted because LiteRT invocation is not safely preemptible.
 */
class VisualSafetyEngine(
    private val classifier: VisualSafetyClassifier,
    private val policy: VisualSafetyPolicy = VisualSafetyPolicy(),
    private val limiter: AdaptiveInferenceLimiter = AdaptiveInferenceLimiter(),
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val submitLock = Any()
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(1),
        ThreadFactory { runnable ->
            Thread(runnable, "AarisVisualSafety").apply { isDaemon = true }
        },
    )

    fun submit(
        frame: VisualFrame,
        onResult: (VisualSafetyResult) -> Unit,
    ): VisualSubmission = synchronized(submitLock) {
        if (closed.get()) return VisualSubmission.CLOSED
        if (!limiter.tryAcquire()) return VisualSubmission.THROTTLED

        val queue = executor.queue
        val replaced = if (queue.remainingCapacity() == 0) {
            queue.poll() != null
        } else {
            false
        }

        executor.execute {
            val outcome = try {
                classifier.classify(frame)
            } catch (_: Exception) {
                VisualClassifierOutcome.Failure(VisualFailureCode.INFERENCE_FAILED)
            }
            if (outcome is VisualClassifierOutcome.Success) {
                limiter.recordInference(outcome.inferenceMillis)
            }
            val result = policy.evaluate(classifier.modelId, outcome)
            if (!closed.get()) onResult(result)
        }

        if (replaced) {
            VisualSubmission.REPLACED_OLDER_PENDING_FRAME
        } else {
            VisualSubmission.ACCEPTED
        }
    }

    override fun close() {
        synchronized(submitLock) {
            if (!closed.compareAndSet(false, true)) return
            executor.queue.clear()
            executor.execute { classifier.close() }
            executor.shutdown()
        }
    }
}
