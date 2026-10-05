package com.aaris.remoteassist.webrtc

/** One bounded recovery deadline; repeated transport callbacks cannot extend it. */
internal class TransportRecoveryWindow(private val budgetMs: Long = 45_000L) {
    private var deadlineMs: Long? = null

    init { require(budgetMs > 0L) }

    @Synchronized
    fun begin(nowMs: Long): Boolean {
        if (deadlineMs != null) return false
        deadlineMs = nowMs + budgetMs
        return true
    }

    @Synchronized
    fun remainingMs(nowMs: Long): Long? = deadlineMs?.let { (it - nowMs).coerceAtLeast(0L) }

    @Synchronized
    fun recovered() { deadlineMs = null }
}
