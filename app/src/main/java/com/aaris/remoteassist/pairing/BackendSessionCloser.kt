package com.aaris.remoteassist.pairing

import android.content.Context
import com.aaris.remoteassist.backend.FirebaseBackend
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

object BackendSessionCloser {
    private val cleanupScope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO
    )

    fun close(context: Context, sessionId: String) {
        if (sessionId.isBlank()) return

        val appContext = context.applicationContext

        runCatching {
            FirebaseBackend.database()
                .getReference("sessions")
                .child(sessionId)
                .child("state")
                .setValue("CLOSED")
        }

        cleanupScope.launch {
            runCatching {
                FirebasePairingGateway(appContext)
                    .close(sessionId)
            }
        }
    }
}
