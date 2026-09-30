package com.aaris.remoteassist.ui

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionState
import java.io.Closeable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class RemoteControlActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val gateway by lazy { FirebasePairingGateway(this) }

    private lateinit var status: TextView
    private var observer: Closeable? = null
    private var sessionId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
        if (sessionId == null) {
            finish()
            return
        }

        setContentView(buildUi())
        observe(sessionId!!)
    }

    override fun onDestroy() {
        observer?.close()
        observer = null
        scope.cancel()
        super.onDestroy()
    }

    private fun observe(id: String) {
        observer = runCatching {
            gateway.observeSession(
                id,
                listener = { backend ->
                    runOnUiThread {
                        status.text = when (backend.state) {
                            "PAIR_PENDING" ->
                                "Waiting for your friend to tap START…"

                            "HOST_APPROVED" ->
                                "Waiting for screen-share permission…"

                            "SCREEN_READY" -> {
                                runCatching {
                                    val current = SessionCoordinator.snapshot()
                                    if (current.state == SessionState.PAIR_PENDING) {
                                        SessionCoordinator.transition(
                                            id,
                                            SessionState.HOST_APPROVED
                                        )
                                    }
                                    val afterApproval = SessionCoordinator.snapshot()
                                    if (afterApproval.state == SessionState.HOST_APPROVED) {
                                        SessionCoordinator.transition(
                                            id,
                                            SessionState.SCREEN_CONSENT
                                        )
                                    }
                                    val afterConsent = SessionCoordinator.snapshot()
                                    if (afterConsent.state == SessionState.SCREEN_CONSENT) {
                                        SessionCoordinator.transition(
                                            id,
                                            SessionState.CONNECTING
                                        )
                                    }
                                }
                                "Screen ready • establishing low-latency link…"
                            }

                            "LIVE" -> "Connected"

                            "CLOSED" -> {
                                SessionCoordinator.close(id)
                                "Session ended"
                            }

                            else -> "Connecting…"
                        }
                    }
                },
                onError = {
                    runOnUiThread {
                        status.text = "Connection lost"
                    }
                }
            )
        }.getOrElse {
            status.text = it.message ?: "Could not watch session"
            null
        }
    }

    private fun disconnect() {
        val id = sessionId ?: return
        scope.launch {
            runCatching { gateway.close(id) }
            SessionCoordinator.close(id)
            finish()
        }
    }

    private fun buildUi(): FrameLayout {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        status = TextView(this).apply {
            text = "Connecting…"
            setTextColor(Color.WHITE)
            textSize = 17f
            gravity = Gravity.CENTER
        }

        root.addView(
            status,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(14, 8, 14, 8)
            setBackgroundColor(Color.argb(180, 0, 0, 0))
        }

        topBar.addView(
            TextView(this).apply {
                text = "Secure remote session"
                setTextColor(Color.WHITE)
                textSize = 13f
            },
            LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f
            )
        )

        topBar.addView(
            Button(this).apply {
                text = "Disconnect"
                isAllCaps = false
                setOnClickListener { disconnect() }
            }
        )

        root.addView(
            topBar,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP
            )
        )

        return root
    }

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
    }
}
