package com.aaris.shield.visual

import org.junit.Assert.assertEquals
import org.junit.Test

class VisualTensorCodecTest {
    @Test
    fun int8RoundTripUsesTensorQuantization() {
        val quantization = VisualQuantization(scale = 0.5f, zeroPoint = -3)
        val buffer = VisualTensorCodec.allocate(1, VisualTensorType.INT8)
        VisualTensorCodec.put(buffer, 12.5f, VisualTensorType.INT8, quantization)
        buffer.rewind()
        assertEquals(12.5f, VisualTensorCodec.get(buffer, VisualTensorType.INT8, quantization), 0.001f)
    }

    @Test
    fun uint8RoundTripTreatsStoredByteAsUnsigned() {
        val quantization = VisualQuantization(scale = 1f, zeroPoint = 128)
        val buffer = VisualTensorCodec.allocate(1, VisualTensorType.UINT8)
        VisualTensorCodec.put(buffer, 100f, VisualTensorType.UINT8, quantization)
        buffer.rewind()
        assertEquals(100f, VisualTensorCodec.get(buffer, VisualTensorType.UINT8, quantization), 0.001f)
    }
}
