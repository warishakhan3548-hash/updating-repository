package com.aaris.remoteassist.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Typeface
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.capture.ScreenShareService
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.pairing.PairingCode
import com.aaris.remoteassist.pairing.RemoteSessionView
import com.aaris.remoteassist.session.SessionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val gateway by lazy { FirebasePairingGateway() }
    private lateinit var codeInput: EditText
    private lateinit var status: TextView

    private var shareAfterSetup = false
    private var watcher: AutoCloseable? = null
    private var approvalDialog: AlertDialog? = null
    private var pendingProjectionSession: RemoteSessionView? = null
    private var controllerLaunchedFor: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())
    }

    override fun onResume() {
        super.onResume()
        if (shareAfterSetup && AssistAccessibilityService.isConnected()) {
            shareAfterSetup = false
            beginShare()
        }
    }

    override fun onDestroy() {
        watcher?.close()
        approvalDialog?.dismiss()
        scope.cancel()
        super.onDestroy()
    }

    @Deprecated("MediaProjection consent uses the platform activity-result contract.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_SCREEN_SHARE) return

        val session = pendingProjectionSession
        pendingProjectionSession = null

        if (resultCode != RESULT_OK || data == null || session == null) {
            status.text = "Screen sharing was cancelled."
            return
        }

        scope.launch {
            runCatching {
                gateway.beginConnecting(session.sessionId)
                ScreenShareService.start(
                    context = this@MainActivity,
                    sessionId = session.sessionId,
                    controllerUid = requireNotNull(session.controllerUid),
                    resultCode = resultCode,
                    permissionData = data
                )
            }.onSuccess {
                status.text = "LIVE · Your screen is ready to connect."
            }.onFailure { showBackendError(it) }
        }
    }

    private fun buildUi(): LinearLayout {
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(52), dp(24), dp(24))
        }

        root.addView(TextView(this).apply {
            text = "Aaris Remote"
            textSize = 28f
            setTypeface(typeface, Typeface.BOLD)
        })

        root.addView(TextView(this).apply {
            text = "Connect with a one-time code"
            textSize = 15f
            setPadding(0, dp(8), 0, dp(28))
        })

        codeInput = EditText(this).apply {
            hint = "000 000"
            gravity = Gravity.CENTER
            inputType = InputType.TYPE_CLASS_NUMBER
            textSize = 24f
            letterSpacing = 0.12f
            isSingleLine = true
        }
        root.addView(codeInput, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(58)
        ))

        root.addView(Button(this).apply {
            text = "Connect"
            setOnClickListener { connect() }
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(58)
        ).apply { topMargin = dp(12) })

        root.addView(Button(this).apply {
            text = "Share my phone"
            setOnClickListener { requestShare() }
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(58)
        ).apply { topMargin = dp(18) })

        status = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 14f
            setPadding(0, dp(22), 0, 0)
        }
        root.addView(status)
        return root
    }

    private fun requestShare() {
        if (!AssistAccessibilityService.isConnected()) {
            shareAfterSetup = true
            status.text = "Turn on Aaris Remote accessibility once, then come back."
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            return
        }
        beginShare()
    }

    private fun beginShare() {
        setBusy("Creating secure one-time code…")
        scope.launch {
            runCatching { gateway.createShareTicket() }
                .onSuccess { ticket ->
                    status.text = "Share code: ${PairingCode.display(ticket.code)}\nIt expires shortly and works once."
                    watchHostSession(ticket.sessionId)
                }
                .onFailure { showBackendError(it) }
        }
    }

    private fun connect() {
        val code = PairingCode.normalize(codeInput.text.toString())
        if (code == null) {
            toast("Enter the 6-digit code")
            return
        }
        setBusy("Finding your friend's phone…")
        scope.launch {
            runCatching { gateway.redeemCode(code) }
                .onSuccess { request ->
                    status.text = "Request sent. Waiting for your friend to press Start."
                    watchControllerSession(request.sessionId)
                }
                .onFailure { showBackendError(it) }
        }
    }

    private fun watchHostSession(sessionId: String) {
        watcher?.close()
        watcher = gateway.watchSession(
            sessionId = sessionId,
            onUpdate = { session ->
                runOnUiThread {
                    when (session.state) {
                        SessionState.PAIR_PENDING -> showApproval(session)
                        SessionState.CLOSED -> status.text = "Session ended."
                        else -> Unit
                    }
                }
            },
            onError = { runOnUiThread { showBackendError(it) } }
        )
    }

    private fun watchControllerSession(sessionId: String) {
        watcher?.close()
        watcher = gateway.watchSession(
            sessionId = sessionId,
            onUpdate = { session ->
                runOnUiThread {
                    if (session.state == SessionState.CONNECTING &&
                        controllerLaunchedFor != session.sessionId
                    ) {
                        controllerLaunchedFor = session.sessionId
                        startActivity(RemoteControlActivity.intentFor(this, session))
                    } else if (session.state == SessionState.CLOSED) {
                        status.text = "Session ended."
                    }
                }
            },
            onError = { runOnUiThread { showBackendError(it) } }
        )
    }

    private fun showApproval(session: RemoteSessionView) {
        if (approvalDialog?.isShowing == true) return
        if (session.controllerUid.isNullOrBlank()) return

        approvalDialog = AlertDialog.Builder(this)
            .setTitle("Start remote support?")
            .setMessage("A device entered your one-time code. Start only if you expect this connection.")
            .setNegativeButton("Decline") { _, _ ->
                scope.launch { runCatching { gateway.close(session.sessionId) } }
            }
            .setPositiveButton("Start") { _, _ ->
                scope.launch {
                    runCatching { gateway.approve(session.sessionId) }
                        .onSuccess { requestScreenShare(session) }
                        .onFailure { showBackendError(it) }
                }
            }
            .setOnDismissListener { approvalDialog = null }
            .show()
    }

    @Suppress("DEPRECATION")
    private fun requestScreenShare(session: RemoteSessionView) {
        pendingProjectionSession = session
        status.text = "Confirm Android screen sharing to continue."
        val manager = getSystemService(MediaProjectionManager::class.java)
        startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_SCREEN_SHARE)
    }

    private fun setBusy(message: String) {
        status.text = message
    }

    private fun showBackendError(error: Throwable) {
        status.text = if (error.message?.contains("FirebaseApp", ignoreCase = true) == true) {
            "Firebase project is not configured on this build yet."
        } else {
            error.message ?: "Could not connect. Try again."
        }
    }

    private fun toast(message: String) =
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()

    companion object {
        private const val REQUEST_SCREEN_SHARE = 7001
    }
}
