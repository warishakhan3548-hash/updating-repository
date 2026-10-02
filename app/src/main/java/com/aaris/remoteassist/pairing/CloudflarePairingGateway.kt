package com.aaris.remoteassist.pairing

import android.content.Context
import com.aaris.remoteassist.backend.CloudflareBackend
import com.aaris.remoteassist.backend.CloudflareBackendException
import java.io.Closeable
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject

class CloudflarePairingGateway(
    context: Context
) : PairingGateway {
    private val appContext = context.applicationContext
    private val secureRandom = SecureRandom()

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
            val controllerToken = generateControllerToken()
            var lastError: Throwable? = null

            repeat(REDEEM_ATTEMPTS) { attempt ->
                try {
                    val root = CloudflareBackend.publicRequest(
                        "POST",
                        "/v1/sessions/redeem",
                        JSONObject()
                            .put("code", normalized)
                            .put(
                                "controllerToken",
                                controllerToken
                            )
                    )
                    val sessionId =
                        root.getString("sessionId")
                    CloudflareBackend.rememberToken(
                        appContext,
                        sessionId,
                        controllerToken
                    )
                    return@withContext PairRequest(
                        sessionId = sessionId,
                        hostUid =
                            root.getString("hostUid"),
                        controllerUid = root
                            .optString("controllerUid")
                            .takeIf(String::isNotBlank)
                    )
                } catch (error: Throwable) {
                    lastError = error
                    if (
                        !isRetryable(error) ||
                        attempt == REDEEM_ATTEMPTS - 1
                    ) {
                        throw error
                    }
                    delay(retryDelayMs(attempt))
                }
            }

            throw lastError
                ?: IllegalStateException(
                    "Could not redeem pairing code."
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
            var lastError: Throwable? = null

            repeat(TRANSITION_ATTEMPTS) { attempt ->
                try {
                    CloudflareBackend.sessionRequest(
                        appContext,
                        sessionId,
                        "POST",
                        "state",
                        JSONObject().put(
                            "target",
                            target
                        )
                    )
                    return@withContext
                } catch (error: Throwable) {
                    lastError = error
                    if (
                        !isRetryable(error) ||
                        attempt ==
                            TRANSITION_ATTEMPTS - 1
                    ) {
                        throw error
                    }
                    delay(retryDelayMs(attempt))
                }
            }

            throw lastError
                ?: IllegalStateException(
                    "Could not update session state."
                )
        }
    }

    private fun generateControllerToken(): String {
        val bytes = ByteArray(32)
        secureRandom.nextBytes(bytes)
        return Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(bytes)
    }

    private fun isRetryable(error: Throwable): Boolean {
        if (error !is CloudflareBackendException) {
            return true
        }
        return error.statusCode >= 500 ||
            error.statusCode == 408 ||
            error.statusCode == 429
    }

    private fun retryDelayMs(attempt: Int): Long =
        (
            RETRY_BASE_MS *
                (1L shl attempt.coerceIn(0, 3))
        ).coerceAtMost(RETRY_MAX_MS)

    companion object {
        private const val REDEEM_ATTEMPTS = 4
        private const val TRANSITION_ATTEMPTS = 4
        private const val RETRY_BASE_MS = 250L
        private const val RETRY_MAX_MS = 2_000L
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
    private var lastBackendState: String? = null

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
                lastBackendState = backend.state
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

                /*
                 * Once screen sharing has reached its transport phase,
                 * backend polling is telemetry/state recovery rather than
                 * transport truth. A short Cloudflare/mobile-network wobble
                 * must not tear down an otherwise healthy WebRTC peer and
                 * ordered control DataChannel.
                 */
                val transportPhase =
                    lastBackendState == "SCREEN_READY" ||
                        lastBackendState == "LIVE"

                if (
                    !transportPhase &&
                    failures >= MAX_CONSECUTIVE_FAILURES
                ) {
                    onError(error)
                    break
                }

                if (transportPhase) {
                    failures = failures.coerceAtMost(
                        MAX_CONSECUTIVE_FAILURES
                    )
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
        private const val MAX_CONSECUTIVE_FAILURES = 6
    }
}
