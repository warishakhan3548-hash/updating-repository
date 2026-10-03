package com.aaris.remoteassist.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Rect
import com.aaris.remoteassist.capture.CaptureVideoContract

/** Recovery packet coordinates describe pixels, independent of either phone's DPI. */
internal object RecoveryBitmapRenderer {
    fun drawPixels(canvas: Canvas, bitmap: Bitmap, x: Int, y: Int) {
        // The float-position overload scales automatically when Bitmap/Canvas
        // densities differ. Explicit rectangles keep every delta in wire pixels.
        canvas.drawBitmap(bitmap, null, Rect(x, y, x + bitmap.width, y + bitmap.height), null)
    }

    fun decode(jpeg: ByteArray, width: Int, height: Int, rotation: Int): Bitmap? {
        val limit = CaptureVideoContract.MAX_FALLBACK_SAFE_LONG_SIDE_PX
        if (width !in 1..limit || height !in 1..limit || rotation !in setOf(0, 90, 180, 270)) return null
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true; inScaled = false }
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
        // Reject mismatched/cropped patches before allocating pixels. A small
        // JPEG must never be accepted as the complete remote display.
        if (options.outWidth != width || options.outHeight != height) return null
        options.inJustDecodeBounds = false
        val decoded = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options) ?: return null
        decoded.density = Bitmap.DENSITY_NONE
        if (rotation == 0) return decoded
        return try {
            Bitmap.createBitmap(decoded, 0, 0, width, height,
                Matrix().apply { postRotate(rotation.toFloat()) }, false).also {
                it.density = Bitmap.DENSITY_NONE
                if (it !== decoded) decoded.recycle()
            }
        } catch (_: RuntimeException) { decoded.recycle(); null }
    }
}
