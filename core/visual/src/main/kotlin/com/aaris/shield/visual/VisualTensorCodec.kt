package com.aaris.shield.visual

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

enum class VisualTensorType(val bytesPerElement: Int) {
    FLOAT32(4),
    UINT8(1),
    INT8(1),
}

data class VisualQuantization(
    val scale: Float,
    val zeroPoint: Int,
) {
    init {
        require(scale.isFinite() && scale > 0f) { "Quantization scale must be positive" }
    }
}

internal object VisualTensorCodec {
    fun allocate(elementCount: Int, type: VisualTensorType): ByteBuffer {
        require(elementCount > 0)
        return ByteBuffer.allocateDirect(elementCount * type.bytesPerElement)
            .order(ByteOrder.nativeOrder())
    }

    fun put(
        buffer: ByteBuffer,
        value: Float,
        type: VisualTensorType,
        quantization: VisualQuantization?,
    ) {
        when (type) {
            VisualTensorType.FLOAT32 -> buffer.putFloat(value)
            VisualTensorType.UINT8 -> {
                val q = requireNotNull(quantization) { "UINT8 tensor requires quantization parameters" }
                val encoded = (value / q.scale + q.zeroPoint).roundToInt().coerceIn(0, 255)
                buffer.put(encoded.toByte())
            }
            VisualTensorType.INT8 -> {
                val q = requireNotNull(quantization) { "INT8 tensor requires quantization parameters" }
                val encoded = (value / q.scale + q.zeroPoint).roundToInt().coerceIn(-128, 127)
                buffer.put(encoded.toByte())
            }
        }
    }

    fun get(
        buffer: ByteBuffer,
        type: VisualTensorType,
        quantization: VisualQuantization?,
    ): Float = when (type) {
        VisualTensorType.FLOAT32 -> buffer.float
        VisualTensorType.UINT8 -> {
            val q = requireNotNull(quantization) { "UINT8 tensor requires quantization parameters" }
            ((buffer.get().toInt() and 0xff) - q.zeroPoint) * q.scale
        }
        VisualTensorType.INT8 -> {
            val q = requireNotNull(quantization) { "INT8 tensor requires quantization parameters" }
            (buffer.get().toInt() - q.zeroPoint) * q.scale
        }
    }
}
