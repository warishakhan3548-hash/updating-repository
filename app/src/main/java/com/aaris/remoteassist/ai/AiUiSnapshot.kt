package com.aaris.remoteassist.ai

import android.graphics.Rect
import org.json.JSONArray

data class AiUiSnapshot(
    val packageName: String,
    val hints: JSONArray,
    val masks: List<Rect>,
    val sensitiveFocus: Boolean,
    val truncated: Boolean
)

object AiObservationSignals {
    // Installed and invoked on the main thread; Accessibility events are not retained.
    var changed: (() -> Unit)? = null
}
