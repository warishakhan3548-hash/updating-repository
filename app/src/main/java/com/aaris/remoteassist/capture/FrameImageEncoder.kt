package com.aaris.remoteassist.capture

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.YuvImage
import java.io.ByteArrayOutputStream
import org.webrtc.VideoFrame

object FrameImageEncoder {
    fun toNv21(buffer: VideoFrame.I420Buffer): ByteArray {
        val w = buffer.width; val h = buffer.height
        val cw = (w + 1) / 2; val ch = (h + 1) / 2
        val result = ByteArray(w * h + cw * ch * 2)
        val y = buffer.dataY.duplicate(); val u = buffer.dataU.duplicate(); val v = buffer.dataV.duplicate()
        for (row in 0 until h) {
            y.position(row * buffer.strideY); y.get(result, row * w, w)
        }
        var out = w * h
        for (row in 0 until ch) for (col in 0 until cw) {
            result[out++] = v.get(row * buffer.strideV + col)
            result[out++] = u.get(row * buffer.strideU + col)
        }
        return result
    }

    data class Encoded(val bytes: ByteArray, val width: Int, val height: Int)
    fun encode(frame: AiRawFrame, maxSide: Int, masks: List<Rect>, displayWidth: Int, displayHeight: Int, hideAll: Boolean): Encoded {
        val out = ByteArrayOutputStream()
        check(YuvImage(frame.nv21, ImageFormat.NV21, frame.width, frame.height, null)
            .compressToJpeg(Rect(0, 0, frame.width, frame.height), 94, out))
        var bitmap = checkNotNull(BitmapFactory.decodeByteArray(out.toByteArray(), 0, out.size()))
        try {
            if (frame.rotation != 0) {
                val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(frame.rotation.toFloat()) }, true)
                if (rotated !== bitmap) { bitmap.recycle(); bitmap = rotated }
            }
            val scale = minOf(1f, maxSide.toFloat() / maxOf(bitmap.width, bitmap.height))
            if (scale < 1f) {
                val resized = Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt().coerceAtLeast(2), (bitmap.height * scale).toInt().coerceAtLeast(2), true)
                if (resized !== bitmap) { bitmap.recycle(); bitmap = resized }
            }
            if (!bitmap.isMutable) {
                val mutable = checkNotNull(bitmap.copy(Bitmap.Config.ARGB_8888, true)); bitmap.recycle(); bitmap = mutable
            }
            val canvas = Canvas(bitmap)
            if (hideAll) canvas.drawColor(Color.BLACK) else {
                val paint = Paint().apply { color = Color.BLACK }
                for (rect in masks) canvas.drawRect(
                    (rect.left - 4) * bitmap.width.toFloat() / displayWidth,
                    (rect.top - 4) * bitmap.height.toFloat() / displayHeight,
                    (rect.right + 4) * bitmap.width.toFloat() / displayWidth,
                    (rect.bottom + 4) * bitmap.height.toFloat() / displayHeight, paint)
            }
            for (quality in intArrayOf(88, 80, 72)) {
                out.reset(); check(bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out))
                if (out.size() <= 850_000) return Encoded(out.toByteArray(), bitmap.width, bitmap.height)
            }
            error("IMAGE_TOO_LARGE")
        } finally { bitmap.recycle() }
    }
}
