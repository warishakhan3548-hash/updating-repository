package com.aaris.remoteassist.pairing

import android.content.Context
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
        cleanupScope.launch {
            runCatching {
                CloudflarePairingGateway(appContext).close(sessionId)
            }
        }
    }
}
