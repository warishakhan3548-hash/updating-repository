package com.aaris.remoteassist.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.aaris.remoteassist.accessibility.PermissionGate
import com.aaris.remoteassist.capture.ScreenShareService
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.pairing.PairingCode
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionState
import java.io.Closeable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val gateway by lazy { FirebasePairingGateway(this) }

    private lateinit var codeInput: EditText
    private lateinit var codeOutput: TextView
    private lateinit var status: TextView
    private lateinit var connectButton: Button
    private lateinit var shareButton: Button

    private var hostObserver: Closeable? = null
    private var approvalDialogSessionId: String? = null
    private var pendingProjectionSessionId: String? = null

    private val prefs by lazy {
        getSharedPreferences("setup", Context.MODE_PRIVATE)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())

        if (PermissionGate.isAccessibilityEnabled(this)) {
            SessionCoordinator.prepareReady()
        }
    }

    override fun onResume() {
        super.onResume()
        if (
            prefs.getBoolean(KEY_PENDING_SHARE, false) &&
            PermissionGate.isAccessibilityEnabled(this)
        ) {
            prefs.edit().putBoolean(KEY_PENDING_SHARE, false).apply()
            SessionCoordinator.prepareReady()
            beginShare()
        }
    }

    override fun onDestroy() {
        hostObserver?.close()
        hostObserver = null
        scope.cancel()
        super.onDestroy()
    }

    @Deprecated("Platform MediaProjection consent callback.")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_MEDIA_PROJECTION) return

        val sessionId = pendingProjectionSessionId
        pendingProjectionSessionId = null

        if (sessionId == null || resultCode != RESULT_OK || data == null) {
            if (sessionId != null) {
                scope.launch { runCatching { gateway.close(sessionId) } }
                SessionCoordinator.close(sessionId)
            }
            status.text = "Screen sharing was not started."
            return
        }

        startForegroundService(
            Intent(this, ScreenShareService::class.java).apply {
                action = ScreenShareService.ACTION_START
                putExtra(ScreenShareService.EXTRA_SESSION_ID, sessionId)
                putExtra(ScreenShareService.EXTRA_RESULT_CODE, resultCode)
                putExtra(ScreenShareService.EXTRA_CAPTURE_DATA, data)
            }
        )
        status.text = "Starting secure connection…"
    }

    private fun requestShare() {
        if (!PermissionGate.isAccessibilityEnabled(this)) {
            prefs.edit().putBoolean(KEY_PENDING_SHARE, true).apply()
            SessionCoordinator.markSetupRequired()
            status.text = "Turn on Aaris Remote accessibility once, then come back."
            PermissionGate.openAccessibilitySettings(this)
            return
        }

        SessionCoordinator.prepareReady()
        beginShare()
    }

    private fun beginShare() {
        setButtonsEnabled(false)
        status.text = "Creating secure one-time code…"

        scope.launch {
            runCatching { gateway.createShareTicket() }
                .onSuccess { ticket ->
                    setButtonsEnabled(true)
                    runCatching {
                        SessionCoordinator.transition(
                            ticket.sessionId,
                            SessionState.CODE_ACTIVE
                        )
                    }
                    codeOutput.visibility = View.VISIBLE
                    codeOutput.text = PairingCode.display(ticket.code)
                    status.text = "Tap the code to copy. It expires shortly and works once."
                    observeHostSession(ticket.sessionId)
                }
                .onFailure {
                    setButtonsEnabled(true)
                    showBackendError(it)
                }
        }
    }

    private fun connect() {
        val code = PairingCode.normalize(codeInput.text.toString())
        if (code == null) {
            toast("Enter the 6-digit code")
            return
        }

        SessionCoordinator.prepareReady()
        setButtonsEnabled(false)
        status.text = "Finding your friend's phone…"

        scope.launch {
            runCatching { gateway.redeemCode(code) }
                .onSuccess { request ->
                    setButtonsEnabled(true)
                    runCatching {
                        SessionCoordinator.transition(
                            request.sessionId,
                            SessionState.PAIR_PENDING
                        )
                    }
                    startActivity(
                        Intent(
                            this@MainActivity,
                            RemoteControlActivity::class.java
                        ).putExtra(
                            RemoteControlActivity.EXTRA_SESSION_ID,
                            request.sessionId
                        )
                    )
                }
                .onFailure {
                    setButtonsEnabled(true)
                    showBackendError(it)
                }
        }
    }

    private fun observeHostSession(sessionId: String) {
        hostObserver?.close()
        hostObserver = runCatching {
            gateway.observeSession(
                sessionId = sessionId,
                listener = { backend ->
                    runOnUiThread {
                        when (backend.state) {
                            "PAIR_PENDING" -> {
                                runCatching {
                                    SessionCoordinator.transition(
                                        sessionId,
                                        SessionState.PAIR_PENDING
                                    )
                                }
                                showApproval(sessionId)
                            }
                            "CLOSED" -> {
                                SessionCoordinator.close(sessionId)
                                codeOutput.visibility = View.GONE
                                status.text = "Session ended."
                            }
                        }
                    }
                },
                onError = {
                    runOnUiThread {
                        status.text = "Connection watcher stopped."
                    }
                }
            )
        }.getOrElse {
            showBackendError(it)
            null
        }
    }

    private fun showApproval(sessionId: String) {
        if (approvalDialogSessionId == sessionId) return
        approvalDialogSessionId = sessionId

        AlertDialog.Builder(this)
            .setTitle("Start remote support?")
            .setMessage(
                "A device entered your one-time code. Start only if you want to share and control this phone now."
            )
            .setPositiveButton("START") { _, _ ->
                approvalDialogSessionId = null
                approveAndRequestScreen(sessionId)
            }
            .setNegativeButton("DECLINE") { _, _ ->
                approvalDialogSessionId = null
                scope.launch { runCatching { gateway.close(sessionId) } }
                SessionCoordinator.close(sessionId)
                codeOutput.visibility = View.GONE
                status.text = "Connection declined."
            }
            .setOnCancelListener {
                approvalDialogSessionId = null
            }
            .show()
    }

    private fun approveAndRequestScreen(sessionId: String) {
        status.text = "Preparing screen share…"
        scope.launch {
            runCatching { gateway.approve(sessionId) }
                .onSuccess {
                    runCatching {
                        SessionCoordinator.transition(
                            sessionId,
                            SessionState.HOST_APPROVED
                        )
                    }
                    pendingProjectionSessionId = sessionId
                    val projectionManager =
                        getSystemService(MediaProjectionManager::class.java)
                    startActivityForResult(
                        projectionManager.createScreenCaptureIntent(),
                        REQUEST_MEDIA_PROJECTION
                    )
                }
                .onFailure { showBackendError(it) }
        }
    }

    private fun copyCode() {
        val text = codeOutput.text.toString()
            .filter(Char::isDigit)
        if (text.length != 6) return

        getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(
                ClipData.newPlainText("Aaris Remote code", text)
            )
        status.text = "Code copied."
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
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))

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
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE) {
                    connect()
                    true
                } else {
                    false
                }
            }
        }

        root.addView(
            codeInput,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(58)
            )
        )

        connectButton = Button(this).apply {
            text = "Connect"
            isAllCaps = false
            setOnClickListener { connect() }
        }

        root.addView(
            connectButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(58)
            ).apply {
                topMargin = dp(12)
            }
        )

        shareButton = Button(this).apply {
            text = "Share my phone"
            isAllCaps = false
            setOnClickListener { requestShare() }
        }

        root.addView(
            shareButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(58)
            ).apply {
                topMargin = dp(18)
            }
        )

        codeOutput = TextView(this).apply {
            visibility = View.GONE
            gravity = Gravity.CENTER
            textSize = 32f
            setPadding(0, dp(20), 0, dp(6))
            setOnClickListener { copyCode() }
        }

        root.addView(codeOutput)

        status = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 14f
            setPadding(0, dp(18), 0, 0)
        }

        root.addView(status)

        return root
    }

    private fun setButtonsEnabled(enabled: Boolean) {
        connectButton.isEnabled = enabled
        shareButton.isEnabled = enabled
    }

    private fun showBackendError(error: Throwable) {
        status.text = error.message ?: "Could not connect. Try again."
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val KEY_PENDING_SHARE = "pending_share"
        private const val REQUEST_MEDIA_PROJECTION = 7001
    }
}
