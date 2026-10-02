package com.aaris.remoteassist.pairing

import android.content.Context
import com.aaris.remoteassist.backend.CloudflareBackend
import com.aaris.remoteassist.backend.CloudflareBackendException
import java.io.Closeable
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

class CloudflarePairingGateway(
    context: Context
) : PairingGateway {
    private val appContext = context.applicationContext

    override suspend fun createShareTicket(): ShareTicket =
        withContext(Dispatchers.IO) {
            val root = CloudflareBackend.publicRequest(
                "POST",
                "/v1/sessions"
            )
            val sessionId = root.getString("sessionId")
            CloudflareBackend.rememberToken(
                appContext,
                sessionId,
                root.getString("hostToken")
            )
            ShareTicket(
                sessionId = sessionId,
                code = root.getString("code"),
                expiresAtEpochMs = root.getLong("expiresAtMs")
            )
        }

    override suspend fun redeemCode(code: String): PairRequest =
        withContext(Dispatchers.IO) {
            val normalized = PairingCode.normalize(code)
                ?: error("Enter a valid 12-digit code")
            val root = CloudflareBackend.publicRequest(
                "POST",
                "/v1/sessions/redeem",
                JSONObject().put("code", normalized)
            )
            val sessionId = root.getString("sessionId")
            CloudflareBackend.rememberToken(
                appContext,
                sessionId,
                root.getString("controllerToken")
            )
            PairRequest(
                sessionId = sessionId,
                hostUid = root.getString("hostUid"),
                controllerUid = root
                    .optString("controllerUid")
                    .takeIf(String::isNotBlank)
            )
        }

    override suspend fun approve(sessionId: String) =
        transition(sessionId, "HOST_APPROVED")

    override suspend fun markScreenReady(sessionId: String) =
        transition(sessionId, "SCREEN_READY")

    override suspend fun markLive(sessionId: String) =
        transition(sessionId, "LIVE")

    override suspend fun close(sessionId: String) {
        withContext(Dispatchers.IO) {
            try {
                CloudflareBackend.sessionRequest(
                    appContext,
                    sessionId,
                    "POST",
                    "close"
                )
            } finally {
                CloudflareBackend.forgetToken(
                    appContext,
                    sessionId
                )
            }
        }
    }

    override fun observeSession(
        sessionId: String,
        listener: (BackendSession) -> Unit,
        onError: (Throwable) -> Unit
    ): Closeable = PollingSessionObserver(
        context = appContext,
        sessionId = sessionId,
        listener = listener,
        onError = onError
    )

    private suspend fun transition(
        sessionId: String,
        target: String
    ) {
        withContext(Dispatchers.IO) {
            CloudflareBackend.sessionRequest(
                appContext,
                sessionId,
                "POST",
                "state",
                JSONObject().put("target", target)
            )
        }
    }
}

private class PollingSessionObserver(
    private val context: Context,
    private val sessionId: String,
    private val listener: (BackendSession) -> Unit,
    private val onError: (Throwable) -> Unit
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor()
    private var lastFingerprint: String? = null

    init {
        executor.execute(::runLoop)
    }

    private fun runLoop() {
        var failures = 0
        while (!closed.get()) {
            try {
                val root = CloudflareBackend.sessionRequest(
                    context,
                    sessionId,
                    "GET"
                )
                val session = root.getJSONObject("session")
                val backend = BackendSession(
                    sessionId = session.getString("sessionId"),
                    state = session.getString("state"),
                    displayGeneration =
                        session.optInt("displayGeneration", 0),
                    deadlineAtEpochMs =
                        if (session.isNull("deadlineAtMs")) {
                            null
                        } else {
                            session.optLong("deadlineAtMs")
                        }
                )
                failures = 0
                val fingerprint =
                    "${backend.state}:" +
                        "${backend.displayGeneration}:" +
                        "${backend.deadlineAtEpochMs}"
                if (fingerprint != lastFingerprint) {
                    lastFingerprint = fingerprint
                    listener(backend)
                }
            } catch (error: Throwable) {
                if (closed.get()) break
                if (
                    error is CloudflareBackendException &&
                    error.statusCode in listOf(401, 403, 404, 410)
                ) {
                    onError(error)
                    break
                }
                failures += 1
                if (failures >= MAX_CONSECUTIVE_FAILURES) {
                    onError(error)
                    break
                }
            }

            try {
                Thread.sleep(POLL_INTERVAL_MS)
            } catch (_: InterruptedException) {
                break
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        executor.shutdownNow()
    }

    companion object {
        private const val POLL_INTERVAL_MS = 650L
        private const val MAX_CONSECUTIVE_FAILURES = 4
    }
}
