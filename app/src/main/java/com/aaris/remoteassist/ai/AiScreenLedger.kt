package com.aaris.remoteassist.ai

/** Single-use observation tickets bind a decision to a screen, geometry and service lifetime. */
class AiScreenLedger {
    var version = 0L
        private set
    var changedAtMs = 0L
        private set
    private var ticket: String? = null
    private var issuedAtMs = 0L
    private var issuedVersion = -1L
    fun changed(nowMs: Long) { version++; changedAtMs = nowMs }
    fun issue(id: String, nowMs: Long) { ticket = id; issuedVersion = version; issuedAtMs = nowMs }
    fun valid(id: String, expectedVersion: Long, nowMs: Long): Boolean =
        ticket == id && version == expectedVersion && issuedVersion == version && nowMs - issuedAtMs in 0..30_000
    fun consume() { ticket = null }
    fun invalidate(nowMs: Long) { consume(); changed(nowMs) }
}

object AiVisualFingerprint {
    // Full luma thumbnail supplements Accessibility events for canvas, WebView and games.
    fun sample(nv21: ByteArray, width: Int, height: Int): ByteArray = ByteArray(48 * 80) { index ->
        val x = ((index % 48 + 0.5) * width / 48).toInt().coerceIn(0, width - 1)
        val y = ((index / 48 + 0.5) * height / 80).toInt().coerceIn(0, height - 1)
        nv21[y * width + x]
    }
    fun materiallyDifferent(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size || a.isEmpty()) return true
        var changed = 0
        for (i in a.indices) if (kotlin.math.abs((a[i].toInt() and 255) - (b[i].toInt() and 255)) > 24) changed++
        return changed > a.size / 100 // Ignore isolated caret/clock noise, reject broad visual movement.
    }
}
