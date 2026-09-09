package com.aaris.pharmacy

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.net.Uri
import android.provider.OpenableColumns
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Platform facts and genuinely on-device speech; never falls back to a network recognizer. */
internal class LocalAiPlatform(private val activity: Activity) {
    companion object { const val microphoneRequest = 4080; const val modelRequest = 4081 }
    private var pending: MethodChannel.Result? = null
    private var recognizer: SpeechRecognizer? = null
    private var locale = "hi-IN"
    private val handler = Handler(Looper.getMainLooper())
    private var speechGeneration = 0L
    private var speechTimeout: Runnable? = null
    private var modelResult: MethodChannel.Result? = null
    @Volatile private var copyingModel = false
    @Volatile private var cancelModel = false

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "localAiDeviceInfo" -> {
                val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val memory = ActivityManager.MemoryInfo()
                manager.getMemoryInfo(memory)
                result.success(mapOf("totalMemory" to memory.totalMem,
                    "sdkInt" to Build.VERSION.SDK_INT, "abis" to Build.SUPPORTED_ABIS.toList(),
                    "availableMemory" to memory.availMem, "lowMemory" to memory.lowMemory,
                    "freeStorage" to StatFs(activity.filesDir.absolutePath).availableBytes,
                    "cores" to Runtime.getRuntime().availableProcessors()))
            }
            "startOfflineSpeech" -> {
                if (pending != null) {
                    result.error("speech_busy", "The microphone is already in use.", null)
                    return true
                }
                if (Build.VERSION.SDK_INT < 31 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)) {
                    result.error("offline_speech_unavailable", "Install an on-device speech service on Android 12 or newer.", null)
                    return true
                }
                val language = call.argument<String>("locale") ?: "hi-IN"
                if (language != "hi-IN" && language != "en-IN") {
                    result.error("invalid_language", "Choose Hindi or English.", null)
                    return true
                }
                locale = language
                pending = result
                if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), microphoneRequest)
                } else start()
            }
            "cancelOfflineSpeech" -> { cancel(); result.success(null) }
            "pickLocalModel" -> pickModel(result)
            "cancelModelImport" -> { cancelModel = true; result.success(null) }
            else -> return false
        }
        return true
    }

    fun permissionResult(granted: Boolean) {
        if (pending == null) return
        if (granted) start() else failPending("Microphone permission was not granted.")
    }

    private fun start() {
        if (pending == null || Build.VERSION.SDK_INT < 31) return
        val generation = ++speechGeneration
        var speech: SpeechRecognizer? = null
        try {
            speech = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            recognizer = speech
            val sessionSpeech = speech
            speech.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onError(error: Int) {
                    finishSpeech(
                        generation,
                        sessionSpeech,
                        null,
                        "On-device speech unavailable or language not installed (code $error).",
                    )
                }
                override fun onResults(results: Bundle?) {
                    val text = results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                    finishSpeech(generation, sessionSpeech, text?.take(3000), null)
                }
            })
            val timeout = Runnable {
                finishSpeech(
                    generation,
                    sessionSpeech,
                    null,
                    "Offline microphone timed out. Try again or type.",
                )
            }
            speechTimeout = timeout
            handler.postDelayed(timeout, 30000)
            speech.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            })
        } catch (_: Exception) {
            // If construction/start failed after creating a recognizer, destroy
            // exactly that recognizer and complete only the still-current request.
            if (speech != null && recognizer === speech && generation == speechGeneration) {
                recognizer = null
                try { speech.cancel(); speech.destroy() } catch (_: Exception) {}
            }
            failPending("Could not start on-device speech. Use the keyboard.")
        }
    }

    /**
     * Completes only the recognizer session that produced this callback.
     * Android speech services can deliver a late onError/onResults after cancel
     * or destroy. Without both the generation and object identity checks, a
     * stale callback from session A can otherwise consume session B's pending
     * MethodChannel result and destroy B's recognizer.
     */
    private fun finishSpeech(
        generation: Long,
        speech: SpeechRecognizer,
        text: String?,
        error: String?,
    ) {
        if (generation != speechGeneration || recognizer !== speech) return
        val result = pending
        pending = null
        recognizer = null
        ++speechGeneration
        speechTimeout?.let(handler::removeCallbacks)
        speechTimeout = null
        try { speech.cancel(); speech.destroy() } catch (_: Exception) {}
        if (error == null) result?.success(text)
        else result?.error("offline_speech_error", error, null)
    }

    private fun failPending(error: String) {
        val result = pending
        pending = null
        ++speechGeneration
        speechTimeout?.let(handler::removeCallbacks)
        speechTimeout = null
        val speech = recognizer
        recognizer = null
        try { speech?.cancel(); speech?.destroy() } catch (_: Exception) {}
        result?.error("offline_speech_error", error, null)
    }

    fun cancel() {
        val result = pending
        pending = null
        ++speechGeneration
        speechTimeout?.let(handler::removeCallbacks)
        speechTimeout = null
        val speech = recognizer
        recognizer = null
        try { speech?.cancel(); speech?.destroy() } catch (_: Exception) {}
        result?.success(null)
    }

    private fun pickModel(result: MethodChannel.Result) {
        if (modelResult != null || copyingModel) {
            result.error("model_import_busy", "A model import is already open.", null)
            return
        }
        modelResult = result
        cancelModel = false
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            }, modelRequest)
        } catch (_: Exception) {
            modelResult = null
            result.error("model_picker_unavailable", "The model file picker is unavailable.", null)
        }
    }

    fun activityResult(requestCode: Int, resultCode: Int, uri: Uri?): Boolean {
        if (requestCode != modelRequest) return false
        val result = modelResult ?: return true
        if (resultCode != Activity.RESULT_OK || uri == null) {
            modelResult = null
            result.success(null)
            return true
        }
        copyingModel = true
        // Multi-GB model import MUST NOT run on onActivityResult's UI thread.
        // Copy once, with a bounded buffer, into the same private model store.
        Thread {
            var target: java.io.File? = null
            try {
                var name = "Imported.gguf"
                var declaredSize = -1L
                activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (nameColumn >= 0) name = cursor.getString(nameColumn) ?: name
                        if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) declaredSize = cursor.getLong(sizeColumn)
                    }
                }
                if (!name.endsWith(".gguf", true)) throw IllegalArgumentException("Select one complete GGUF model file.")
                val reserve = 512L * 1024 * 1024
                val free = StatFs(activity.filesDir.absolutePath).availableBytes
                if (declaredSize > 0 && declaredSize > free - reserve) throw IllegalArgumentException("Not enough private storage for this model.")
                val root = java.io.File(activity.filesDir, "local_ai").apply { mkdirs() }
                val output = java.io.File(root, "import_${java.util.UUID.randomUUID()}.part")
                target = output
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                var copied = 0L
                activity.contentResolver.openInputStream(uri).use { input ->
                    if (input == null) throw IllegalArgumentException("Cannot open the selected model.")
                    java.io.FileOutputStream(output).use { stream ->
                        val buffer = ByteArray(128 * 1024)
                        while (true) {
                            if (cancelModel) throw IllegalStateException("Model import cancelled.")
                            val count = input.read(buffer)
                            if (count < 0) break
                            copied += count
                            if (copied > free - reserve || copied > 128L * 1024 * 1024 * 1024) {
                                throw IllegalArgumentException("Model import exceeds free storage or the file limit.")
                            }
                            stream.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                        }
                        stream.fd.sync()
                    }
                }
                if (copied < 1024 || (declaredSize > 0 && copied != declaredSize)) throw IllegalArgumentException("Model file is incomplete.")
                val hash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                activity.runOnUiThread {
                    if (modelResult !== result) { output.delete(); return@runOnUiThread }
                    modelResult = null
                    if (cancelModel) { output.delete(); result.error("model_cancelled", "Model import cancelled.", null) }
                    else result.success(mapOf("path" to output.absolutePath, "name" to name, "bytes" to copied, "sha256" to hash))
                }
            } catch (error: Exception) {
                target?.delete()
                activity.runOnUiThread {
                    if (modelResult === result) {
                        modelResult = null
                        result.error("model_import_error", error.message, null)
                    }
                }
            } finally { copyingModel = false }
        }.start()
        return true
    }

    fun dispose() {
        cancel()
        cancelModel = true
        val result = modelResult
        modelResult = null
        result?.error("activity_closed", "Model import interrupted. Select the file again.", null)
    }
}
