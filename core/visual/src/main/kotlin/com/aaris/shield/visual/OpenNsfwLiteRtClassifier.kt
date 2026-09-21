package com.aaris.shield.visual

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.security.MessageDigest
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.Tensor

/**
 * Local-only Yahoo OpenNSFW-compatible classifier. The model is packaged as an
 * uncompressed app asset by the module build and is never downloaded at runtime.
 */
class OpenNsfwLiteRtClassifier(
    context: Context,
    private val threadCount: Int = 2,
) : VisualSafetyClassifier {
    private val appContext = context.applicationContext
    private var interpreter: Interpreter? = null

    @Volatile
    private var modelLifecycle = VisualModelLifecycle.UNINITIALIZED

    override val modelId: String = MODEL_ID
    override val lifecycle: VisualModelLifecycle get() = modelLifecycle

    init {
        require(threadCount in 1..4) { "threadCount must be in 1..4" }
    }

    @Synchronized
    override fun initialize(): VisualModelLifecycle {
        when (modelLifecycle) {
            VisualModelLifecycle.READY,
            VisualModelLifecycle.FAILED,
            VisualModelLifecycle.CLOSED -> return modelLifecycle
            VisualModelLifecycle.LOADING -> return VisualModelLifecycle.LOADING
            VisualModelLifecycle.UNINITIALIZED -> Unit
        }

        modelLifecycle = VisualModelLifecycle.LOADING
        return try {
            verifyBundledModel()
            val mappedModel = mapModelAsset()
            val created = Interpreter(
                mappedModel,
                Interpreter.Options().setNumThreads(threadCount),
            )
            validateModelContract(created)
            interpreter = created
            modelLifecycle = VisualModelLifecycle.READY
            modelLifecycle
        } catch (_: Exception) {
            interpreter?.close()
            interpreter = null
            modelLifecycle = VisualModelLifecycle.FAILED
            modelLifecycle
        }
    }

    @Synchronized
    override fun classify(frame: VisualFrame): VisualClassifierOutcome {
        if (modelLifecycle == VisualModelLifecycle.CLOSED) {
            return VisualClassifierOutcome.Failure(VisualFailureCode.MODEL_UNAVAILABLE)
        }
        if (initialize() != VisualModelLifecycle.READY) {
            return VisualClassifierOutcome.Failure(VisualFailureCode.MODEL_UNAVAILABLE)
        }

        val runtime = interpreter
            ?: return VisualClassifierOutcome.Failure(VisualFailureCode.MODEL_UNAVAILABLE)

        return try {
            val inputTensor = runtime.getInputTensor(0)
            val outputTensor = runtime.getOutputTensor(0)
            val inputType = inputTensor.dataType().toVisualTensorType()
            val outputType = outputTensor.dataType().toVisualTensorType()
            val inputQuantization = inputTensor.visualQuantization(inputType)
            val outputQuantization = outputTensor.visualQuantization(outputType)

            val started = SystemClock.elapsedRealtimeNanos()
            val input = preprocess(frame, inputType, inputQuantization)
            val output = VisualTensorCodec.allocate(OUTPUT_CLASSES, outputType)
            runtime.run(input, output)
            val elapsedMillis = (SystemClock.elapsedRealtimeNanos() - started)
                .coerceAtLeast(0L) / 1_000_000L

            output.rewind()
            val safe = VisualTensorCodec.get(output, outputType, outputQuantization)
            val unsafe = VisualTensorCodec.get(output, outputType, outputQuantization)
            if (!validProbabilityPair(safe, unsafe)) {
                VisualClassifierOutcome.Failure(VisualFailureCode.INFERENCE_FAILED)
            } else {
                VisualClassifierOutcome.Success(
                    scores = VisualModelScores(
                        safeProbability = safe,
                        unsafeProbability = unsafe,
                    ),
                    inferenceMillis = elapsedMillis,
                )
            }
        } catch (_: Exception) {
            VisualClassifierOutcome.Failure(VisualFailureCode.INFERENCE_FAILED)
        }
    }

    @Synchronized
    override fun close() {
        if (modelLifecycle == VisualModelLifecycle.CLOSED) return
        interpreter?.close()
        interpreter = null
        modelLifecycle = VisualModelLifecycle.CLOSED
    }

    private fun verifyBundledModel() {
        val digest = MessageDigest.getInstance("SHA-1")
        digest.update("blob $EXPECTED_MODEL_BYTES\u0000".toByteArray(Charsets.UTF_8))
        var count = 0L
        appContext.assets.open(MODEL_ASSET).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
                count += read
                require(count <= EXPECTED_MODEL_BYTES) { "Visual model is larger than expected" }
            }
        }
        require(count == EXPECTED_MODEL_BYTES) { "Visual model size mismatch" }
        val actual = digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        require(actual == EXPECTED_GIT_BLOB_SHA1) { "Visual model integrity check failed" }
    }

    private fun mapModelAsset(): ByteBuffer = appContext.assets.openFd(MODEL_ASSET).use { descriptor ->
        require(descriptor.declaredLength == EXPECTED_MODEL_BYTES) { "Visual model asset length mismatch" }
        FileInputStream(descriptor.fileDescriptor).channel.use { channel ->
            channel.map(
                FileChannel.MapMode.READ_ONLY,
                descriptor.startOffset,
                descriptor.declaredLength,
            ).order(ByteOrder.nativeOrder())
        }
    }

    private fun validateModelContract(runtime: Interpreter) {
        require(runtime.inputTensorCount == 1) { "Visual model must have exactly one input" }
        require(runtime.outputTensorCount == 1) { "Visual model must have exactly one output" }

        val input = runtime.getInputTensor(0)
        val inputShape = input.shape()
        require(inputShape.contentEquals(intArrayOf(1, INPUT_SIZE, INPUT_SIZE, 3))) {
            "Unexpected visual model input shape: ${inputShape.contentToString()}"
        }
        input.dataType().toVisualTensorType()
        input.visualQuantization(input.dataType().toVisualTensorType())

        val output = runtime.getOutputTensor(0)
        val outputElements = output.shape().fold(1) { product, dimension -> product * dimension }
        require(outputElements == OUTPUT_CLASSES) { "Visual model must output SFW/NSFW probabilities" }
        output.dataType().toVisualTensorType()
        output.visualQuantization(output.dataType().toVisualTensorType())
    }

    private fun preprocess(
        frame: VisualFrame,
        type: VisualTensorType,
        quantization: VisualQuantization?,
    ): ByteBuffer {
        val source = Bitmap.createBitmap(
            frame.argb,
            frame.width,
            frame.height,
            Bitmap.Config.ARGB_8888,
        )
        val scaled = Bitmap.createScaledBitmap(source, RESIZE_SIZE, RESIZE_SIZE, true)
        if (scaled !== source) source.recycle()

        val crop = IntArray(INPUT_SIZE * INPUT_SIZE)
        val offset = (RESIZE_SIZE - INPUT_SIZE) / 2
        try {
            scaled.getPixels(crop, 0, INPUT_SIZE, offset, offset, INPUT_SIZE, INPUT_SIZE)
        } finally {
            scaled.recycle()
        }

        val input = VisualTensorCodec.allocate(INPUT_SIZE * INPUT_SIZE * 3, type)
        for (pixel in crop) {
            val blue = (pixel and 0xff).toFloat() - VGG_BLUE_MEAN
            val green = ((pixel ushr 8) and 0xff).toFloat() - VGG_GREEN_MEAN
            val red = ((pixel ushr 16) and 0xff).toFloat() - VGG_RED_MEAN
            VisualTensorCodec.put(input, blue, type, quantization)
            VisualTensorCodec.put(input, green, type, quantization)
            VisualTensorCodec.put(input, red, type, quantization)
        }
        input.rewind()
        return input
    }

    private fun DataType.toVisualTensorType(): VisualTensorType = when (this) {
        DataType.FLOAT32 -> VisualTensorType.FLOAT32
        DataType.UINT8 -> VisualTensorType.UINT8
        DataType.INT8 -> VisualTensorType.INT8
        else -> throw IllegalArgumentException("Unsupported visual model tensor type: $this")
    }

    private fun Tensor.visualQuantization(type: VisualTensorType): VisualQuantization? {
        if (type == VisualTensorType.FLOAT32) return null
        val params = quantizationParams()
        return VisualQuantization(scale = params.scale, zeroPoint = params.zeroPoint)
    }

    private fun validProbabilityPair(safe: Float, unsafe: Float): Boolean {
        if (!safe.isFinite() || !unsafe.isFinite()) return false
        if (safe !in 0f..1f || unsafe !in 0f..1f) return false
        return kotlin.math.abs((safe + unsafe) - 1f) <= 0.10f
    }

    companion object {
        const val MODEL_ID = "yahoo-open-nsfw-tflite-devzwy-a1b49e0"
        const val MODEL_ASSET = "aaris_shield/open_nsfw.tflite"
        const val EXPECTED_MODEL_BYTES = 23_591_976L
        const val EXPECTED_GIT_BLOB_SHA1 = "9583ed20d47ded82738891744c7983b3fe1f2bd3"

        private const val INPUT_SIZE = 224
        private const val RESIZE_SIZE = 256
        private const val OUTPUT_CLASSES = 2
        private const val VGG_BLUE_MEAN = 103.939f
        private const val VGG_GREEN_MEAN = 116.779f
        private const val VGG_RED_MEAN = 123.68f
    }
}
