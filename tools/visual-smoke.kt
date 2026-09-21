import com.aaris.shield.visual.AdaptiveInferenceLimiter
import com.aaris.shield.visual.VisualClassifierOutcome
import com.aaris.shield.visual.VisualFailureCode
import com.aaris.shield.visual.VisualModelScores
import com.aaris.shield.visual.VisualSafetyPolicy
import com.aaris.shield.visual.VisualSafetyState

fun main() {
    val policy = VisualSafetyPolicy()
    fun classify(score: Float) = policy.evaluate(
        modelId = "smoke",
        outcome = VisualClassifierOutcome.Success(
            scores = VisualModelScores(1f - score, score),
            inferenceMillis = 25L,
        ),
    ).state

    check(classify(0.19f) == VisualSafetyState.SAFE)
    check(classify(0.20f) == VisualSafetyState.AMBIGUOUS)
    check(classify(0.80f) == VisualSafetyState.AMBIGUOUS)
    check(classify(0.81f) == VisualSafetyState.UNSAFE)
    check(
        policy.evaluate(
            "smoke",
            VisualClassifierOutcome.Failure(VisualFailureCode.MODEL_UNAVAILABLE),
        ).state == VisualSafetyState.AMBIGUOUS,
    )

    val limiter = AdaptiveInferenceLimiter(
        minimumIntervalMillis = 80L,
        maximumIntervalMillis = 1_000L,
        latencyHeadroom = 2.0,
        smoothing = 1.0,
    )
    check(limiter.tryAcquire(0L))
    limiter.recordInference(300L)
    check(limiter.currentIntervalMillis() == 600L)
    check(!limiter.tryAcquire(500_000_000L))
    check(limiter.tryAcquire(600_000_000L))

    println("Aaris Shield visual policy smoke checks: PASS")
}
