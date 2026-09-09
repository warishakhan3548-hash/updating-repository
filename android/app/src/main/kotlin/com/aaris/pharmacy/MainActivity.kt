package com.aaris.pharmacy

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream
import java.text.NumberFormat
import java.util.Locale
import java.nio.charset.StandardCharsets
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    private val localAiPlatform by lazy { LocalAiPlatform(this) }
    private val documentsChannel = "com.aaris.pharmacy/documents"
    private val pickTextRequest = 4071
    private val pickImageRequest = 4072
    private val pickVideoRequest = 4073
    private var pendingTextResult: MethodChannel.Result? = null
    private var pendingMediaResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, documentsChannel)
            .setMethodCallHandler { call, result ->
                if (localAiPlatform.handle(call, result)) return@setMethodCallHandler
                when (call.method) {
                    "createPurchaseOrderPdf" -> {
                        @Suppress("UNCHECKED_CAST")
                        val arguments = call.arguments as? Map<String, Any?>
                        if (arguments == null) {
                            result.error("invalid_order", "Purchase-order data is missing.", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val path = createPurchaseOrderPdf(arguments)
                                runOnUiThread { result.success(path) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "pdf_error",
                                        error.message ?: "The PDF could not be created.",
                                        null,
                                    )
                                }
                            }
                        }.start()
                    }
                    "pickTextDocument" -> pickTextDocument(result)
                    "pickImportSource" -> {
                        val kind = call.argument<String>("kind")
                        pickImportSource(kind, result)
                    }
                    "sampleVideo" -> {
                        val path = call.argument<String>("path")
                        val maxFrames = call.argument<Int>("maxFrames") ?: 60
                        if (path == null) {
                            result.error("invalid_video", "Video path is missing.", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val frames = sampleVideo(path, maxFrames.coerceIn(1, 72))
                                runOnUiThread { result.success(frames) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "video_error",
                                        error.message ?: "The video could not be processed.",
                                        null,
                                    )
                                }
                            }
                        }.start()
                    }
                    "sampleVideoWindow" -> {
                        val path = call.argument<String>("path")
                        val start = call.argument<Number>("startMs")?.toLong() ?: 0L
                        if (path == null || start < 0) {
                            result.error("invalid_video", "Invalid video window.", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val duration = videoDuration(path)
                                if (duration > 3_600_000L) throw IllegalArgumentException("Split videos longer than one hour.")
                                val end = minOf(start + 20_000L, duration)
                                val frames = if (start >= duration) emptyList() else sampleVideo(path, 24, start, end)
                                runOnUiThread { result.success(mapOf("frames" to frames,
                                    "durationMs" to duration, "nextStartMs" to end)) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("video_window_error", error.message, null) }
                            }
                        }.start()
                    }
                    "deleteImportFiles" -> {
                        val paths = call.argument<List<String>>("paths").orEmpty()
                        Thread {
                            val deleted = deleteImportFiles(paths)
                            runOnUiThread { result.success(deleted) }
                        }.start()
                    }
                    "deleteCameraCapture" -> {
                        val path = call.argument<String>("path").orEmpty()
                        Thread {
                            val deleted = deleteCameraCapture(path)
                            runOnUiThread { result.success(deleted) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickTextDocument(result: MethodChannel.Result) {
        if (pendingTextResult != null || pendingMediaResult != null) {
            result.error("picker_busy", "Another file selection is already open.", null)
            return
        }
        pendingTextResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/json", "text/json", "text/plain", "application/octet-stream"),
            )
        }
        try {
            startActivityForResult(intent, pickTextRequest)
        } catch (error: Exception) {
            pendingTextResult = null
            result.error("picker_unavailable", "A document picker is unavailable.", null)
        }
    }

    private fun pickImportSource(kind: String?, result: MethodChannel.Result) {
        if (kind != "image" && kind != "video") {
            result.error("invalid_source", "Choose an image or video.", null)
            return
        }
        if (pendingTextResult != null || pendingMediaResult != null) {
            result.error("picker_busy", "Another file selection is already open.", null)
            return
        }
        pendingMediaResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (kind == "image") "image/*" else "video/*"
        }
        try {
            startActivityForResult(
                intent,
                if (kind == "image") pickImageRequest else pickVideoRequest,
            )
        } catch (error: Exception) {
            pendingMediaResult = null
            result.error("picker_unavailable", "A media picker is unavailable.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickImageRequest || requestCode == pickVideoRequest) {
            handlePickedMedia(requestCode, resultCode, data?.data)
            return
        }
        if (requestCode != pickTextRequest) return
        val pending = pendingTextResult ?: return
        pendingTextResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        Thread {
            try {
                val output = ByteArrayOutputStream()
                contentResolver.openInputStream(uri).use { input ->
                    if (input == null) throw IllegalArgumentException("The selected file could not be opened.")
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        if (output.size() > 12_000_000) {
                            throw IllegalArgumentException("The selected file is larger than 12 MB.")
                        }
                    }
                }
                val text = output.toString(StandardCharsets.UTF_8.name())
                runOnUiThread { pending.success(text) }
            } catch (error: Exception) {
                runOnUiThread {
                    pending.error(
                        "file_read_error",
                        error.message ?: "The selected file could not be read.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun handlePickedMedia(requestCode: Int, resultCode: Int, uri: Uri?) {
        val pending = pendingMediaResult ?: return
        pendingMediaResult = null
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        Thread {
            var partialOutput: File? = null
            try {
                val mime = contentResolver.getType(uri).orEmpty()
                val originalName = displayName(uri)
                val safeName = originalName
                    .replace(Regex("[^a-zA-Z0-9._-]+"), "_")
                    .takeLast(120)
                    .ifEmpty {
                        if (requestCode == pickImageRequest) "medicine_image.jpg"
                        else "medicine_video.mp4"
                    }
                val directory = File(cacheDir, "inventory_imports").apply { mkdirs() }
                directory.listFiles()?.filter {
                    System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000L
                }?.forEach { it.deleteRecursively() }
                val output = File(directory, "${System.currentTimeMillis()}_$safeName")
                partialOutput = output
                var total = 0L
                contentResolver.openInputStream(uri).use { input ->
                    if (input == null) {
                        throw IllegalArgumentException("The selected media could not be opened.")
                    }
                    FileOutputStream(output).use { stream ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            stream.write(buffer, 0, count)
                            total += count
                            val limit = if (requestCode == pickImageRequest) {
                                40_000_000L
                            } else {
                                2_000_000_000L
                            }
                            if (total > limit) {
                                throw IllegalArgumentException(
                                    if (requestCode == pickImageRequest) {
                                        "Choose an image smaller than 40 MB."
                                    } else {
                                        "Choose a video smaller than 2 GB."
                                    },
                                )
                            }
                        }
                    }
                }
                val response = mapOf(
                    "path" to output.absolutePath,
                    "name" to originalName,
                    "mimeType" to mime,
                )
                runOnUiThread { pending.success(response) }
            } catch (error: Exception) {
                partialOutput?.deleteRecursively()
                runOnUiThread {
                    pending.error(
                        "media_read_error",
                        error.message ?: "The selected media could not be read.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun displayName(uri: Uri): String {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )
            if (cursor != null && cursor.moveToFirst()) {
                cursor.getString(0) ?: "selected_media"
            } else {
                "selected_media"
            }
        } finally {
            cursor?.close()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == LocalAiPlatform.microphoneRequest) {
            localAiPlatform.permissionResult(grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED)
        }
    }

    override fun onStop() {
        localAiPlatform.cancel()
        super.onStop()
    }

    override fun onDestroy() {
        localAiPlatform.cancel()
        pendingTextResult?.error("activity_closed", "File selection was cancelled.", null)
        pendingTextResult = null
        pendingMediaResult?.error("activity_closed", "File selection was cancelled.", null)
        pendingMediaResult = null
        super.onDestroy()
    }

    private data class FrameMetrics(
        val hash: Long,
        val sharpness: Double,
        val contrast: Double,
        val exposure: Double,
        val quality: Double,
    )

    private fun videoSource(path: String): File {
        val source = File(path).canonicalFile
        val roots = listOf(File(cacheDir, "inventory_imports").canonicalFile,
            File(filesDir, "medicine_intake").canonicalFile)
        if (!source.isFile || roots.none { source.path.startsWith(it.path + File.separator) }) {
            throw IllegalArgumentException("The selected video is no longer available.")
        }
        return source
    }

    private fun videoDuration(path: String): Long {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(videoSource(path).absolutePath)
            return retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.takeIf { it > 0 }
                ?: throw IllegalArgumentException("Video duration unavailable.")
        } finally { retriever.release() }
    }

    private fun sampleVideo(path: String, maxFrames: Int, startMs: Long = 0L, endMs: Long? = null): List<Map<String, Any>> {
        val source = videoSource(path)
        val retriever = MediaMetadataRetriever()
        var frameDirectory: File? = null
        try {
            retriever.setDataSource(source.absolutePath)
            val totalDurationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?: throw IllegalArgumentException("The video duration could not be read.")
            val durationMs = minOf(endMs ?: totalDurationMs, totalDurationMs) - startMs
            if (durationMs < 1) return emptyList()
            val sourceWidth = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull()
                ?: 0
            val sourceHeight = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull()
                ?: 0
            val intervalMs = when {
                durationMs <= 20_000L -> 650.0
                durationMs <= 60_000L -> 900.0
                durationMs <= 180_000L -> 1_400.0
                else -> durationMs.toDouble() / maxFrames.coerceAtLeast(1)
            }
            val proposed = (ceil(durationMs / intervalMs).toInt() + 1).coerceAtLeast(1)
            val count = minOf(maxFrames, proposed)
            val frameRoot = File(cacheDir, "video_frames").apply { mkdirs() }
            frameRoot.listFiles()?.filter {
                System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000L
            }?.forEach { it.deleteRecursively() }
            val directory = File(frameRoot, java.util.UUID.randomUUID().toString()).apply { mkdirs() }
            frameDirectory = directory
            val acceptedHashes = mutableListOf<Pair<Long, Long>>()
            val result = mutableListOf<Map<String, Any>>()

            for (index in 0 until count) {
                // Sample the middle of each bucket. Exact endpoints are often
                // black transition frames and add no medicine evidence.
                val timeUs = startMs * 1000L + durationMs * 1000L * (index * 2L + 1L) / (count * 2L)
                val largestSource = maxOf(sourceWidth, sourceHeight)
                val sourceScale = minOf(1.0, 1600.0 / largestSource.coerceAtLeast(1))
                val scaledWidth = (sourceWidth * sourceScale).toInt().coerceAtLeast(1)
                val scaledHeight = (sourceHeight * sourceScale).toInt().coerceAtLeast(1)
                val original = if (
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 &&
                    sourceWidth > 0 &&
                    sourceHeight > 0
                ) {
                    retriever.getScaledFrameAtTime(
                        timeUs,
                        MediaMetadataRetriever.OPTION_CLOSEST,
                        scaledWidth,
                        scaledHeight,
                    )
                } else {
                    retriever.getFrameAtTime(
                        timeUs,
                        MediaMetadataRetriever.OPTION_CLOSEST,
                    )
                } ?: continue
                var frame: Bitmap? = null
                try {
                val metrics = imageMetrics(original)
                val timestampMs = timeUs / 1000L
                val duplicate = acceptedHashes.takeLast(8).any {
                    // Similar-looking cartons can have different tiny expiry
                    // text. Do not throw those away using a coarse hash distance.
                    abs(timestampMs - it.second) <= 600L && it.first == metrics.hash
                }
                if (duplicate || metrics.quality < 0.16) {
                    original.recycle()
                    continue
                }
                acceptedHashes.add(metrics.hash to timestampMs)
                val largest = maxOf(original.width, original.height)
                val scale = minOf(1.0, 1600.0 / largest.coerceAtLeast(1))
                val width = (original.width * scale).toInt().coerceAtLeast(1)
                val height = (original.height * scale).toInt().coerceAtLeast(1)
                val outputFrame = if (width == original.width && height == original.height) {
                    original
                } else {
                    Bitmap.createScaledBitmap(original, width, height, true).also {
                        original.recycle()
                    }
                }
                frame = outputFrame
                val file = File(directory, "frame_${index.toString().padStart(3, '0')}.jpg")
                FileOutputStream(file).use { stream ->
                    if (!outputFrame.compress(Bitmap.CompressFormat.JPEG, 92, stream)) {
                        throw IllegalStateException("A sampled frame could not be saved.")
                    }
                }
                outputFrame.recycle()
                result.add(
                    mapOf(
                        "path" to file.absolutePath,
                        "sequence" to timestampMs.toInt(),
                        "timestampMs" to timestampMs,
                        "quality" to metrics.quality,
                    ),
                )
                } finally {
                    frame?.let { if (!it.isRecycled) it.recycle() }
                    if (!original.isRecycled) original.recycle()
                }
            }
            if (result.isEmpty() && endMs == null) {
                throw IllegalArgumentException(
                    "No clear frame could be sampled. Try a shorter, steadier video.",
                )
            }
            return result
        } catch (error: Exception) {
            frameDirectory?.deleteRecursively()
            throw error
        } finally {
            retriever.release()
        }
    }

    private fun deleteImportFiles(paths: List<String>): Int {
        if (paths.size > 100) return 0
        val roots = listOf(
            File(cacheDir, "inventory_imports").canonicalFile,
            File(cacheDir, "video_frames").canonicalFile,
        )
        var deleted = 0
        for (path in paths.distinct()) {
            try {
                val target = File(path).canonicalFile
                val allowed = roots.any { root ->
                    target.path.startsWith(root.path + File.separator)
                }
                if (allowed && target.exists() && target.deleteRecursively()) deleted += 1
            } catch (_: Exception) {
                // Temporary-file cleanup is best effort and never affects inventory facts.
            }
        }
        return deleted
    }

    private fun deleteCameraCapture(path: String): Boolean {
        if (path.isBlank()) return false
        return try {
            val root = cacheDir.canonicalFile
            val target = File(path).canonicalFile
            val allowed = target.isFile &&
                target.path.startsWith(root.path + File.separator)
            allowed && target.delete()
        } catch (_: Exception) {
            false
        }
    }

    private fun imageMetrics(bitmap: Bitmap): FrameMetrics {
        val side = 32
        val small = Bitmap.createScaledBitmap(bitmap, side, side, false)
        val pixels = IntArray(side * side)
        small.getPixels(pixels, 0, side, 0, 0, side, side)
        if (small !== bitmap) small.recycle()
        val luminance = pixels.map { color ->
            (Color.red(color) * 299.0 +
                Color.green(color) * 587.0 +
                Color.blue(color) * 114.0) / 1000.0
        }
        val average = luminance.average()
        val variance = luminance.sumOf { value ->
            val distance = value - average
            distance * distance
        } / luminance.size
        val contrast = sqrt(variance)
        var hash = 0L
        for (y in 0 until 8) {
            for (x in 0 until 8) {
                val value = luminance[(y * 4 + 2) * side + (x * 4 + 2)]
                val bit = y * 8 + x
                if (value >= average) hash = hash or (1L shl bit)
            }
        }
        var edge = 0.0
        var edgeCount = 0
        for (y in 0 until side) {
            for (x in 0 until side) {
                val index = y * side + x
                if (x > 0) {
                    edge += abs(luminance[index] - luminance[index - 1])
                    edgeCount += 1
                }
                if (y > 0) {
                    edge += abs(luminance[index] - luminance[index - side])
                    edgeCount += 1
                }
            }
        }
        val sharpness = (edge / edgeCount.coerceAtLeast(1) / 28.0).coerceIn(0.0, 1.0)
        val contrastScore = (contrast / 58.0).coerceIn(0.0, 1.0)
        val exposure = (1.0 - abs(average - 128.0) / 128.0).coerceIn(0.0, 1.0)
        val quality = (sharpness * 0.52 + contrastScore * 0.28 + exposure * 0.20)
            .coerceIn(0.0, 1.0)
        return FrameMetrics(hash, sharpness, contrast, exposure, quality)
    }

    private fun createPurchaseOrderPdf(arguments: Map<String, Any?>): String {
        val title = (arguments["title"] as? String)?.take(100)
            ?: "Aaris Pharmacy Purchase Order"
        val date = (arguments["date"] as? String)?.take(30) ?: ""
        val rawLines = arguments["lines"] as? List<*>
            ?: throw IllegalArgumentException("No order lines were supplied.")
        if (rawLines.isEmpty() || rawLines.size > 500) {
            throw IllegalArgumentException("Choose between 1 and 500 order lines.")
        }

        val document = PdfDocument()
        val body = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(23, 59, 52)
            textSize = 9f
            typeface = Typeface.create("sans-serif", Typeface.NORMAL)
        }
        val small = Paint(body).apply {
            color = Color.rgb(96, 116, 108)
            textSize = 7.5f
        }
        val heading = Paint(body).apply {
            textSize = 19f
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
        }
        val tableHeading = Paint(body).apply {
            textSize = 8f
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
        }
        val rule = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(218, 229, 220)
            strokeWidth = 1f
        }
        var pageNumber = 0
        var page: PdfDocument.Page? = null
        lateinit var canvas: Canvas
        var y = 0f

        fun beginPage() {
            page?.let(document::finishPage)
            pageNumber += 1
            page = document.startPage(
                PdfDocument.PageInfo.Builder(595, 842, pageNumber).create(),
            )
            canvas = page!!.canvas
            canvas.drawText(title, 32f, 45f, heading)
            canvas.drawText("Date: $date", 32f, 65f, small)
            canvas.drawText("Page $pageNumber", 520f, 65f, small)
            canvas.drawLine(32f, 78f, 563f, 78f, rule)
            canvas.drawText("Medicine", 32f, 98f, tableHeading)
            canvas.drawText("Stock", 302f, 98f, tableHeading)
            canvas.drawText("Order", 360f, 98f, tableHeading)
            canvas.drawText("Unit cost", 418f, 98f, tableHeading)
            canvas.drawText("Amount", 500f, 98f, tableHeading)
            canvas.drawLine(32f, 106f, 563f, 106f, rule)
            y = 126f
        }

        fun drawFitted(text: String, x: Float, baseline: Float, width: Float, paint: Paint) {
            var value = text.replace(Regex("[\\r\\n]+"), " ").trim()
            if (value.isEmpty()) value = "—"
            while (value.length > 1 && paint.measureText(value) > width) {
                value = value.dropLast(1)
            }
            if (value != text.replace(Regex("[\\r\\n]+"), " ").trim()) {
                value = value.dropLast(minOf(1, value.length)) + "…"
            }
            canvas.drawText(value, x, baseline, paint)
        }

        fun integer(line: Map<*, *>, key: String): Long? {
            val number = line[key] as? Number ?: return null
            return number.toLong()
        }

        fun money(paise: Long?): String {
            if (paise == null) return "Unavailable"
            val format = NumberFormat.getCurrencyInstance(Locale("en", "IN"))
            return format.format(paise / 100.0)
        }

        try {
            beginPage()
            var knownTotal = 0L
            var unknownAmounts = 0
            rawLines.forEachIndexed { index, raw ->
                val line = raw as? Map<*, *>
                    ?: throw IllegalArgumentException("Order line ${index + 1} is invalid.")
                val name = (line["name"] as? String)?.take(300)?.trim().orEmpty()
                if (name.isEmpty()) {
                    throw IllegalArgumentException("Order line ${index + 1} has no medicine name.")
                }
                if (y > 775f) beginPage()
                val strength = (line["strength"] as? String)?.take(100)?.trim().orEmpty()
                val salt = (line["salt"] as? String)?.take(300)?.trim().orEmpty()
                val reason = (line["reason"] as? String)?.take(200)?.trim().orEmpty()
                val current = integer(line, "currentQuantity")
                val quantity = integer(line, "quantity")
                    ?: throw IllegalArgumentException("Order quantity is missing.")
                val unitCost = integer(line, "unitCostPaise")
                if (quantity < 1 || quantity > 100_000_000) {
                    throw IllegalArgumentException("Order quantity is outside the supported range.")
                }
                if (current != null && (current < 0 || current > 100_000_000)) {
                    throw IllegalArgumentException("Current stock is outside the supported range.")
                }
                if (unitCost != null && (unitCost < 0 || unitCost > 99_999_999_999L)) {
                    throw IllegalArgumentException("Unit cost is outside the supported range.")
                }
                val amount = unitCost?.let { Math.multiplyExact(quantity, it) }
                if (amount == null) {
                    unknownAmounts += 1
                } else {
                    knownTotal = Math.addExact(knownTotal, amount)
                }

                drawFitted(
                    if (strength.isEmpty()) name else "$name · $strength",
                    32f,
                    y,
                    252f,
                    body,
                )
                drawFitted(current?.toString() ?: "Unknown", 302f, y, 48f, body)
                drawFitted(quantity.toString(), 360f, y, 48f, body)
                drawFitted(money(unitCost), 418f, y, 72f, body)
                drawFitted(money(amount), 500f, y, 63f, body)
                drawFitted(
                    listOf(salt, reason).filter { it.isNotEmpty() }.joinToString(" · "),
                    32f,
                    y + 17f,
                    520f,
                    small,
                )
                canvas.drawLine(32f, y + 29f, 563f, y + 29f, rule)
                y += 45f
            }

            if (y > 735f) beginPage()
            canvas.drawText("Estimated total with known costs", 302f, y + 16f, tableHeading)
            drawFitted(money(knownTotal), 500f, y + 16f, 63f, tableHeading)
            canvas.drawText(
                if (unknownAmounts == 0) {
                    "All selected rows include a saved unit cost."
                } else {
                    "$unknownAmounts row(s) are excluded because unit cost is unavailable."
                },
                302f,
                y + 34f,
                small,
            )
            canvas.drawText(
                "Review quantities, prices and supplier terms before ordering.",
                32f,
                816f,
                small,
            )
            page?.let(document::finishPage)
            page = null

            val directory = File(cacheDir, "purchase_orders").apply { mkdirs() }
            directory.listFiles()?.filter {
                System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000L
            }?.forEach { it.delete() }
            val output = File(directory, "Aaris_Pharmacy_Order_${System.currentTimeMillis()}.pdf")
            FileOutputStream(output).use { stream -> document.writeTo(stream) }
            return output.absolutePath
        } finally {
            page?.let(document::finishPage)
            document.close()
        }
    }
}
