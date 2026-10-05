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
import kotlin.math.ceil
import kotlin.math.floor
import org.webrtc.VideoFrame

object FrameImageEncoder {
    fun toNv21(buffer: VideoFrame.I420Buffer): ByteArray {
        val w = buffer.width
        val h = buffer.height
        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        val result = ByteArray(w * h + cw * ch * 2)
        val y = buffer.dataY.duplicate()
        val u = buffer.dataU.duplicate()
        val v = buffer.dataV.duplicate()
        for (row in 0 until h) {
            y.position(row * buffer.strideY)
            y.get(result, row * w, w)
        }
        var out = w * h
        for (row in 0 until ch) {
            for (col in 0 until cw) {
                result[out++] = v.get(row * buffer.strideV + col)
                result[out++] = u.get(row * buffer.strideU + col)
            }
        }
        return result
    }

    data class Encoded(
        val bytes: ByteArray,
        val width: Int,
        val height: Int
    )

    internal fun canUseDirectNv21Path(
        frame: AiRawFrame,
        maxSide: Int,
        masks: List<Rect>,
        hideAll: Boolean
    ): Boolean =
        frame.rotation == 0 &&
            !hideAll &&
            masks.isEmpty() &&
            maxOf(frame.width, frame.height) <= maxSide

    fun encode(
        frame: AiRawFrame,
        maxSide: Int,
        masks: List<Rect>,
        displayWidth: Int,
        displayHeight: Int,
        hideAll: Boolean,
        region: AiImageRegion? = null
    ): Encoded {
        val out = ByteArrayOutputStream()

        /*
         * The common no-transform visual path does not need Bitmap at all.
         * A region request intentionally leaves this path: cropping must happen
         * in upright display coordinates after rotation and privacy handling.
         */
        if (
            region == null &&
            canUseDirectNv21Path(
                frame = frame,
                maxSide = maxSide,
                masks = masks,
                hideAll = hideAll
            )
        ) {
            val yuv =
                YuvImage(
                    frame.nv21,
                    ImageFormat.NV21,
                    frame.width,
                    frame.height,
                    null
                )
            for (quality in OUTPUT_JPEG_QUALITIES) {
                out.reset()
                check(
                    yuv.compressToJpeg(
                        Rect(0, 0, frame.width, frame.height),
                        quality,
                        out
                    )
                )
                if (out.size() <= MAX_ENCODED_BYTES) {
                    return Encoded(
                        out.toByteArray(),
                        frame.width,
                        frame.height
                    )
                }
            }
            error("IMAGE_TOO_LARGE")
        }

        check(
            YuvImage(
                frame.nv21,
                ImageFormat.NV21,
                frame.width,
                frame.height,
                null
            ).compressToJpeg(
                Rect(0, 0, frame.width, frame.height),
                SOURCE_JPEG_QUALITY,
                out
            )
        )
        var bitmap =
            checkNotNull(
                BitmapFactory.decodeByteArray(
                    out.toByteArray(),
                    0,
                    out.size()
                )
            )

        try {
            if (frame.rotation != 0) {
                val rotated =
                    Bitmap.createBitmap(
                        bitmap,
                        0,
                        0,
                        bitmap.width,
                        bitmap.height,
                        Matrix().apply {
                            postRotate(frame.rotation.toFloat())
                        },
                        true
                    )
                if (rotated !== bitmap) {
                    bitmap.recycle()
                    bitmap = rotated
                }
            }

            /*
             * Region coordinates are defined over the upright full display.
             * Apply privacy to the full upright image before cropping so no mask
             * boundary can be lost by the crop transform.
             */
            if (region != null) {
                if (hideAll || masks.isNotEmpty()) {
                    bitmap = ensureMutable(bitmap)
                    drawPrivacy(
                        bitmap = bitmap,
                        masks = masks,
                        displayWidth = displayWidth,
                        displayHeight = displayHeight,
                        hideAll = hideAll
                    )
                }

                val crop = cropRect(
                    region = region,
                    width = bitmap.width,
                    height = bitmap.height
                )
                val cropped =
                    Bitmap.createBitmap(
                        bitmap,
                        crop.left,
                        crop.top,
                        crop.width(),
                        crop.height()
                    )
                if (cropped !== bitmap) {
                    bitmap.recycle()
                    bitmap = cropped
                }
            }

            val scale =
                minOf(
                    1f,
                    maxSide.toFloat() /
                        maxOf(bitmap.width, bitmap.height)
                )
            if (scale < 1f) {
                val resized =
                    Bitmap.createScaledBitmap(
                        bitmap,
                        (bitmap.width * scale)
                            .toInt()
                            .coerceAtLeast(2),
                        (bitmap.height * scale)
                            .toInt()
                            .coerceAtLeast(2),
                        true
                    )
                if (resized !== bitmap) {
                    bitmap.recycle()
                    bitmap = resized
                }
            }

            /*
             * The ordinary full-frame path keeps the previous cheaper order:
             * scale first, then apply privacy. Region delivery already applied
             * privacy before cropping above.
             */
            if (
                region == null &&
                (hideAll || masks.isNotEmpty())
            ) {
                bitmap = ensureMutable(bitmap)
                drawPrivacy(
                    bitmap = bitmap,
                    masks = masks,
                    displayWidth = displayWidth,
                    displayHeight = displayHeight,
                    hideAll = hideAll
                )
            }

            for (quality in OUTPUT_JPEG_QUALITIES) {
                out.reset()
                check(
                    bitmap.compress(
                        Bitmap.CompressFormat.JPEG,
                        quality,
                        out
                    )
                )
                if (out.size() <= MAX_ENCODED_BYTES) {
                    return Encoded(
                        out.toByteArray(),
                        bitmap.width,
                        bitmap.height
                    )
                }
            }
            error("IMAGE_TOO_LARGE")
        } finally {
            bitmap.recycle()
        }
    }

    internal data class CropBounds(
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int
    )

    internal fun cropBounds(
        region: AiImageRegion,
        width: Int,
        height: Int
    ): CropBounds {
        require(width > 0 && height > 0)

        val left =
            floor(region.left * width)
                .toInt()
                .coerceIn(0, width - 1)
        val top =
            floor(region.top * height)
                .toInt()
                .coerceIn(0, height - 1)
        val right =
            ceil(region.right * width)
                .toInt()
                .coerceIn(left + 1, width)
        val bottom =
            ceil(region.bottom * height)
                .toInt()
                .coerceIn(top + 1, height)

        return CropBounds(left, top, right, bottom)
    }

    internal fun cropRect(
        region: AiImageRegion,
        width: Int,
        height: Int
    ): Rect {
        val bounds = cropBounds(region, width, height)
        return Rect(
            bounds.left,
            bounds.top,
            bounds.right,
            bounds.bottom
        )
    }

    private fun ensureMutable(source: Bitmap): Bitmap {
        if (source.isMutable) return source
        val mutable =
            checkNotNull(
                source.copy(
                    Bitmap.Config.ARGB_8888,
                    true
                )
            )
        source.recycle()
        return mutable
    }

    private fun drawPrivacy(
        bitmap: Bitmap,
        masks: List<Rect>,
        displayWidth: Int,
        displayHeight: Int,
        hideAll: Boolean
    ) {
        val canvas = Canvas(bitmap)
        if (hideAll) {
            canvas.drawColor(Color.BLACK)
            return
        }

        if (displayWidth <= 0 || displayHeight <= 0) {
            canvas.drawColor(Color.BLACK)
            return
        }

        val paint =
            Paint().apply {
                color = Color.BLACK
            }
        for (rect in masks) {
            canvas.drawRect(
                (rect.left - MASK_PADDING_PX) *
                    bitmap.width.toFloat() /
                    displayWidth,
                (rect.top - MASK_PADDING_PX) *
                    bitmap.height.toFloat() /
                    displayHeight,
                (rect.right + MASK_PADDING_PX) *
                    bitmap.width.toFloat() /
                    displayWidth,
                (rect.bottom + MASK_PADDING_PX) *
                    bitmap.height.toFloat() /
                    displayHeight,
                paint
            )
        }
    }

    private val OUTPUT_JPEG_QUALITIES =
        intArrayOf(88, 80, 72)

    private const val SOURCE_JPEG_QUALITY = 94
    private const val MASK_PADDING_PX = 4
    private const val MAX_ENCODED_BYTES = 850_000
}
