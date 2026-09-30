package com.aaris.remoteassist.capture

import android.content.Intent
import java.util.concurrent.atomic.AtomicReference

data class ProjectionGrant(
    val sessionId: String,
    val resultCode: Int,
    val permissionData: Intent
)

object ProjectionGrantStore {
    private val grant = AtomicReference<ProjectionGrant?>(null)

    fun put(sessionId: String, resultCode: Int, permissionData: Intent) {
        grant.set(
            ProjectionGrant(
                sessionId = sessionId,
                resultCode = resultCode,
                permissionData = Intent(permissionData)
            )
        )
    }

    fun take(sessionId: String): ProjectionGrant? {
        while (true) {
            val current = grant.get() ?: return null
            if (current.sessionId != sessionId) return null
            if (grant.compareAndSet(current, null)) return current
        }
    }

    fun clear(sessionId: String?) {
        while (true) {
            val current = grant.get() ?: return
            if (sessionId != null && current.sessionId != sessionId) return
            if (grant.compareAndSet(current, null)) return
        }
    }
}
