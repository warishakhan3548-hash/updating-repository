package com.aaris.remoteassist.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertNull

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RecoveryBitmapRendererTest {
    @Test fun patchesKeepTheirPixelBoundsAcrossDifferentDensities() {
        for (targetDensity in intArrayOf(160, 320, 440, 560)) {
            val patch = Bitmap.createBitmap(12, 16, Bitmap.Config.ARGB_8888).apply {
                density = 160
                eraseColor(Color.RED)
            }
            val composite = Bitmap.createBitmap(80, 100, Bitmap.Config.ARGB_8888).apply {
                density = targetDensity
                eraseColor(Color.BLUE)
            }
            RecoveryBitmapRenderer.drawPixels(Canvas(composite), patch, 10, 20)
            assertEquals("patch inside at DPI $targetDensity", Color.RED, composite.getPixel(21, 35))
            assertEquals("patch must not grow at DPI $targetDensity", Color.BLUE, composite.getPixel(22, 36))
            assertEquals(Color.BLUE, composite.getPixel(40, 60))
            patch.recycle(); composite.recycle()
        }
    }

    @Test fun repeatedCompositeCopiesDoNotMagnifyOrCropTheBase() {
        var base = Bitmap.createBitmap(60, 100, Bitmap.Config.ARGB_8888).apply {
            density = 160
            for (y in 0 until height) for (x in 0 until width) {
                setPixel(x, y, if ((x / 10 + y / 10) % 2 == 0) Color.RED else Color.GREEN)
            }
        }
        val expected = IntArray(6000).also { base.getPixels(it, 0, 60, 0, 0, 60, 100) }
        repeat(30) { n ->
            val next = Bitmap.createBitmap(60, 100, Bitmap.Config.ARGB_8888).apply {
                density = if (n % 2 == 0) 480 else 160
            }
            RecoveryBitmapRenderer.drawPixels(Canvas(next), base, 0, 0)
            base.recycle(); base = next
        }
        val actual = IntArray(6000).also { base.getPixels(it, 0, 60, 0, 0, 60, 100) }
        org.junit.Assert.assertArrayEquals(expected, actual)
        base.recycle()
    }

    @Test fun jpegDimensionsAndRotationMustMatchTheWireContract() {
        val bitmap = Bitmap.createBitmap(20, 40, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
        val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
        assertNull(RecoveryBitmapRenderer.decode(bytes, 200, 400, 0))
        assertNull(RecoveryBitmapRenderer.decode(bytes, 20, 40, 45))
        assertNull(RecoveryBitmapRenderer.decode(byteArrayOf(1, 2, 3), 20, 40, 0))
        for (rotation in intArrayOf(0, 90, 180, 270)) {
            val decoded = checkNotNull(RecoveryBitmapRenderer.decode(bytes, 20, 40, rotation))
            assertEquals(if (rotation % 180 == 0) 20 else 40, decoded.width)
            assertEquals(if (rotation % 180 == 0) 40 else 20, decoded.height)
            assertEquals(Bitmap.DENSITY_NONE, decoded.density)
            decoded.recycle()
        }
        bitmap.recycle()
    }
}
