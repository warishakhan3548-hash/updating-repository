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
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Platform facts and genuinely on-device speech; never falls back to a network recognizer. */
internal class LocalAiPlatform(private val activity: Activity) {
    companion object { const val microphoneRequest = 4080 }
    private var pending: MethodChannel.Result? = null
    private var recognizer: SpeechRecognizer? = null
    private var locale = "hi-IN"
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { finish(null, "Offline microphone timed out. Try again or type.") }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "localAiDeviceInfo" -> {
                val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val memory = ActivityManager.MemoryInfo()
                manager.getMemoryInfo(memory)
                result.success(mapOf("totalMemory" to memory.totalMem,
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
            else -> return false
        }
        return true
    }

    fun permissionResult(granted: Boolean) {
        if (pending == null) return
        if (granted) start() else finish(null, "Microphone permission was not granted.")
    }

    private fun start() {
        if (pending == null || Build.VERSION.SDK_INT < 31) return
        try {
            val speech = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            recognizer = speech
            speech.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onError(error: Int) { finish(null, "On-device speech unavailable or language not installed (code $error).") }
                override fun onResults(results: Bundle?) {
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    finish(text?.take(3000), null)
                }
            })
            handler.postDelayed(timeout, 30000)
            speech.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            })
        } catch (_: Exception) { finish(null, "Could not start on-device speech. Use the keyboard.") }
    }

    private fun finish(text: String?, error: String?) {
        val result = pending
        pending = null
        handler.removeCallbacks(timeout)
        val speech = recognizer
        recognizer = null
        try { speech?.cancel(); speech?.destroy() } catch (_: Exception) {}
        if (error == null) result?.success(text)
        else result?.error("offline_speech_error", error, null)
    }
    fun cancel() = finish(null, null)
}
