package com.aaris.remoteassist.webrtc

/** Send a sharper still frame once after motion settles; never flood a slow link. */
class FallbackClarityPolicy {
    private var changedAt = 0L
    private var refined = false
    fun changed(nowMs: Long) { changedAt = nowMs; refined = false }
    fun shouldRefine(nowMs: Long, interacting: Boolean, congested: Boolean): Boolean =
        !refined && !interacting && !congested && nowMs - changedAt >= 350L
    fun sentRefinement() { refined = true }
}
