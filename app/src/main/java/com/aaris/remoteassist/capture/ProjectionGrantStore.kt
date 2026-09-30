package com.aaris.remoteassist.capture

import android.content.Intent
import java.util.concurrent.atomic.AtomicReference

data class ProjectionGrant(
    val sessionId: String,
    val resultCode: Int,
    val data: Intent
)

object ProjectionGrantStore {
    private val grantRef = AtomicReference<ProjectionGrant?>()

    fun offer(sessionId: String, resultCode: Int, data: Intent) {
        grantRef.set(
            ProjectionGrant(
                sessionId = sessionId,
                resultCode = resultCode,
                data = Intent(data)
            )
        )
    }

    fun consume(sessionId: String): ProjectionGrant? {
        while (true) {
            val current = grantRef.get() ?: return null
            if (current.sessionId != sessionId) return null
            if (grantRef.compareAndSet(current, null)) return current
        }
    }

    fun clear(sessionId: String) {
        val current = grantRef.get() ?: return
        if (current.sessionId == sessionId) {
            grantRef.compareAndSet(current, null)
        }
    }
}
