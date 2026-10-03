package com.aaris.remoteassist.ai

/** Single-use observation tickets bind a decision to a screen, geometry and service lifetime. */
class AiScreenLedger {
    var version = 0L
        private set
    var changedAtMs = 0L
        private set
    var eventRevision = 0L
        private set
    var invalidationGeneration = 0L
        private set
    private var ticket: String? = null
    private var issuedAtMs = 0L
    private var issuedVersion = -1L
    // Events are hints, not evidence that the requested target moved. Streaming
    // text, clocks and overlays used to revoke every action, including Home.
    fun changed(nowMs: Long) { eventRevision++; changedAtMs = nowMs }
    fun issue(id: String, nowMs: Long) { version++; ticket = id; issuedVersion = version; issuedAtMs = nowMs }
    fun valid(id: String, expectedVersion: Long, nowMs: Long): Boolean =
        ticket == id && issuedVersion == expectedVersion && nowMs - issuedAtMs in 0..90_000
    fun consume() { ticket = null }
    fun invalidate(nowMs: Long) { consume(); invalidationGeneration++; changed(nowMs) }
}

object AiVisualFingerprint {
    const val WIDTH = 240
    const val HEIGHT = 432
    // Upright Y/V/U samples: color-only changes also matter, and region checks
    // must use the same orientation as the image and normalized action.
    fun sample(nv21: ByteArray, width: Int, height: Int, rotation: Int = 0): ByteArray {
        require(rotation in setOf(0, 90, 180, 270))
        val result = ByteArray(WIDTH * HEIGHT * 3)
        for (index in 0 until WIDTH * HEIGHT) {
            val u = (index % WIDTH + 0.5) / WIDTH
            val v = (index / WIDTH + 0.5) / HEIGHT
            val (sx, sy) = when (rotation) {
                90 -> v to 1.0 - u
                180 -> 1.0 - u to 1.0 - v
                270 -> 1.0 - v to u
                else -> u to v
            }
            val x = (sx * width).toInt().coerceIn(0, width - 1)
            val y = (sy * height).toInt().coerceIn(0, height - 1)
            val chroma = width * height + (y / 2) * ((width + 1) / 2) * 2 + (x / 2) * 2
            result[index * 3] = nv21[y * width + x]
            result[index * 3 + 1] = nv21[chroma]
            result[index * 3 + 2] = nv21[chroma + 1]
        }
        return result
    }
    fun materiallyDifferent(a: ByteArray, b: ByteArray, scope: AiActionScope): Boolean {
        if (a.size != WIDTH * HEIGHT * 3 || b.size != a.size) return true
        var changed = 0; var samples = 0
        for (i in 0 until WIDTH * HEIGHT) {
            if (!scope.contains((i % WIDTH + 0.5) / WIDTH, (i / WIDTH + 0.5) / HEIGHT)) continue
            samples++
            if ((0..2).any { channel -> kotlin.math.abs((a[i * 3 + channel].toInt() and 255) - (b[i * 3 + channel].toInt() and 255)) > 24 }) changed++
        }
        return samples == 0 || changed > samples / 25 // At most 4% local antialias/caret noise.
    }
}
