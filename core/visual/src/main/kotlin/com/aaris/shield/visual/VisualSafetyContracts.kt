package com.aaris.shield.visual

import java.io.Closeable

enum class VisualSafetyState {
    SAFE,
    AMBIGUOUS,
    UNSAFE,
}

data class VisualSafetyThresholds(
    val safeBelow: Float = 0.20f,
    val unsafeAbove: Float = 0.80f,
) {
    init {
        require(safeBelow in 0f..1f) { "safeBelow must be in [0, 1]" }
        require(unsafeAbove in 0f..1f) { "unsafeAbove must be in [0, 1]" }
        require(safeBelow < unsafeAbove) { "safeBelow must be lower than unsafeAbove" }
    }
}

data class VisualModelScores(
    val safeProbability: Float,
    val unsafeProbability: Float,
) {
    init {
        require(safeProbability.isFinite() && safeProbability in 0f..1f) {
            "safeProbability must be finite and in [0, 1]"
        }
        require(unsafeProbability.isFinite() && unsafeProbability in 0f..1f) {
            "unsafeProbability must be finite and in [0, 1]"
        }
    }
}

enum class VisualFailureCode {
    MODEL_UNAVAILABLE,
    INVALID_MODEL,
    INFERENCE_FAILED,
}

sealed interface VisualClassifierOutcome {
    data class Success(
        val scores: VisualModelScores,
        val inferenceMillis: Long,
    ) : VisualClassifierOutcome {
        init {
            require(inferenceMillis >= 0L) { "inferenceMillis must not be negative" }
        }
    }

    data class Failure(
        val code: VisualFailureCode,
    ) : VisualClassifierOutcome
}

data class VisualSafetyResult(
    val state: VisualSafetyState,
    val modelId: String,
    val scores: VisualModelScores?,
    val inferenceMillis: Long?,
    val failure: VisualFailureCode?,
)

enum class VisualModelLifecycle {
    UNINITIALIZED,
    LOADING,
    READY,
    FAILED,
    CLOSED,
}

class VisualFrame private constructor(
    val width: Int,
    val height: Int,
    internal val argb: IntArray,
    val capturedAtNanos: Long,
) {
    companion object {
        fun fromArgb(
            width: Int,
            height: Int,
            pixels: IntArray,
            capturedAtNanos: Long = System.nanoTime(),
        ): VisualFrame {
            require(width > 0 && height > 0) { "Frame dimensions must be positive" }
            require(width.toLong() * height.toLong() == pixels.size.toLong()) {
                "Pixel count does not match frame dimensions"
            }
            return VisualFrame(width, height, pixels.copyOf(), capturedAtNanos)
        }
    }
}

interface VisualSafetyClassifier : Closeable {
    val modelId: String
    val lifecycle: VisualModelLifecycle

    fun initialize(): VisualModelLifecycle

    fun classify(frame: VisualFrame): VisualClassifierOutcome
}

enum class VisualSubmission {
    ACCEPTED,
    REPLACED_OLDER_PENDING_FRAME,
    THROTTLED,
    CLOSED,
}
