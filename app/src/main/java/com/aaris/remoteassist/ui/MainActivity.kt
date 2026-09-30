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
import com.aaris.remoteassist.pairing.ShareTicket
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionState
import java.io.Closeable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val gateway by lazy { FirebasePairingGateway(this) }

    private lateinit var status: TextView
    private lateinit var connectButton: Button
    private lateinit var shareButton: Button

    private var hostObserver: Closeable? = null
    private var shareDialog: AlertDialog? = null
    private var approvalDialog: AlertDialog? = null
    private var shareExpiryJob: Job? = null
    private var activeHostSessionId: String? = null
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
        refreshIdleUi()
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
            return
        }

        refreshIdleUi()
    }

    override fun onDestroy() {
        hostObserver?.close()
        hostObserver = null
        shareExpiryJob?.cancel()
        shareExpiryJob = null
        shareDialog?.dismiss()
        shareDialog = null
        approvalDialog?.dismiss()
        approvalDialog = null
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
                endHostSession(
                    sessionId = sessionId,
                    message = "Screen sharing was not started."
                )
            } else {
                status.text = "Screen sharing was not started."
            }
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
        if (!isIdleForNewSession()) {
            toast("Finish the current session first")
            return
        }

        if (!PermissionGate.isAccessibilityEnabled(this)) {
            prefs.edit().putBoolean(KEY_PENDING_SHARE, true).apply()
            SessionCoordinator.markSetupRequired()
            status.text = "Enable Aaris Remote once, then return here."
            PermissionGate.openAccessibilitySettings(this)
            return
        }

        SessionCoordinator.prepareReady()
        beginShare()
    }

    private fun beginShare() {
        clearHostUi()
        setButtonsEnabled(false)
        status.text = "Creating secure one-time code…"

        scope.launch {
            runCatching { gateway.createShareTicket() }
                .onSuccess { ticket ->
                    activeHostSessionId = ticket.sessionId
                    runCatching {
                        SessionCoordinator.transition(
                            ticket.sessionId,
                            SessionState.CODE_ACTIVE
                        )
                    }.onFailure {
                        endHostSession(
                            ticket.sessionId,
                            "Could not start a new session."
                        )
                        return@onSuccess
                    }

                    status.text = "Code ready. Send it to the other phone."
                    showShareCode(ticket)
                    observeHostSession(ticket.sessionId)
                    scheduleShareExpiry(ticket)
                }
                .onFailure {
                    setButtonsEnabled(true)
                    showBackendError(it)
                }
        }
    }

    private fun showConnectDialog() {
        if (!isIdleForNewSession()) {
            toast("Finish the current session first")
            return
        }

        val input = EditText(this).apply {
            hint = "000 000"
            gravity = Gravity.CENTER
            inputType = InputType.TYPE_CLASS_NUMBER
            textSize = 24f
            letterSpacing = 0.12f
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_DONE
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle("Connect")
            .setMessage("Enter the 6-digit code from your friend.")
            .setView(input)
            .setPositiveButton("START", null)
            .setNegativeButton("CANCEL", null)
            .create()

        fun submit() {
            val code = PairingCode.normalize(input.text.toString())
            if (code == null) {
                input.error = "Enter the 6-digit code"
                return
            }
            dialog.dismiss()
            connect(code)
        }

        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                .setOnClickListener { submit() }
        }

        input.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) {
                submit()
                true
            } else {
                false
            }
        }

        dialog.show()
        input.requestFocus()
    }

    private fun connect(code: String) {
        SessionCoordinator.prepareReady()
        setButtonsEnabled(false)
        status.text = "Finding your friend's phone…"

        scope.launch {
            runCatching { gateway.redeemCode(code) }
                .onSuccess { request ->
                    runCatching {
                        SessionCoordinator.transition(
                            request.sessionId,
                            SessionState.PAIR_PENDING
                        )
                    }.onFailure {
                        setButtonsEnabled(true)
                        status.text = "Could not start this connection."
                        return@onSuccess
                    }

                    status.text = "Connection request sent."
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
                        if (activeHostSessionId != sessionId) {
                            return@runOnUiThread
                        }

                        when (backend.state) {
                            "PAIR_PENDING" -> {
                                runCatching {
                                    SessionCoordinator.transition(
                                        sessionId,
                                        SessionState.PAIR_PENDING
                                    )
                                }
                                shareDialog?.dismiss()
                                shareDialog = null
                                showApproval(sessionId)
                            }

                            "HOST_APPROVED" ->
                                status.text = "Waiting for screen permission…"

                            "SCREEN_READY",
                            "CONNECTING" ->
                                status.text = "Connecting phones…"

                            "LIVE" ->
                                status.text =
                                    "Remote support is LIVE. Tap STOP • LIVE any time."

                            "CLOSED" -> {
                                SessionCoordinator.close(sessionId)
                                clearHostUi()
                                status.text = "Session ended."
                                refreshIdleUi()
                            }
                        }
                    }
                },
                onError = {
                    runOnUiThread {
                        if (activeHostSessionId == sessionId) {
                            status.text = "Connection watcher stopped."
                        }
                    }
                }
            )
        }.getOrElse {
            showBackendError(it)
            null
        }
    }

    private fun showShareCode(ticket: ShareTicket) {
        shareDialog?.dismiss()

        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        val codeView = TextView(this).apply {
            text = PairingCode.display(ticket.code)
            textSize = 34f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(24), dp(20), dp(24), dp(20))
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle("Share this code")
            .setMessage("It works once and expires shortly.")
            .setView(codeView)
            .setPositiveButton("SEND", null)
            .setNeutralButton("COPY", null)
            .setNegativeButton("CANCEL", null)
            .setCancelable(false)
            .create()

        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                .setOnClickListener {
                    sendCode(ticket.code)
                }

            dialog.getButton(AlertDialog.BUTTON_NEUTRAL)
                .setOnClickListener {
                    copyCode(ticket.code)
                }

            dialog.getButton(AlertDialog.BUTTON_NEGATIVE)
                .setOnClickListener {
                    dialog.dismiss()
                    endHostSession(
                        ticket.sessionId,
                        "Sharing cancelled."
                    )
                }
        }

        shareDialog = dialog
        dialog.show()
    }

    private fun showApproval(sessionId: String) {
        if (approvalDialog?.isShowing == true) return

        val dialog = AlertDialog.Builder(this)
            .setTitle("Start remote support?")
            .setMessage(
                "A device entered your one-time code. Start only if you want to share and control this phone now."
            )
            .setPositiveButton("START") { _, _ ->
                approvalDialog = null
                approveAndRequestScreen(sessionId)
            }
            .setNegativeButton("DECLINE") { _, _ ->
                approvalDialog = null
                endHostSession(
                    sessionId,
                    "Connection declined."
                )
            }
            .setCancelable(false)
            .create()

        approvalDialog = dialog
        dialog.show()
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
                    }.onFailure {
                        endHostSession(
                            sessionId,
                            "Session state changed. Try again."
                        )
                        return@onSuccess
                    }

                    pendingProjectionSessionId = sessionId
                    val projectionManager =
                        getSystemService(MediaProjectionManager::class.java)
                    startActivityForResult(
                        projectionManager.createScreenCaptureIntent(),
                        REQUEST_MEDIA_PROJECTION
                    )
                }
                .onFailure {
                    endHostSession(
                        sessionId,
                        it.message ?: "Could not approve this connection."
                    )
                }
        }
    }

    private fun scheduleShareExpiry(ticket: ShareTicket) {
        shareExpiryJob?.cancel()
        shareExpiryJob = scope.launch {
            val remaining =
                (ticket.expiresAtEpochMs - System.currentTimeMillis())
                    .coerceAtLeast(0L)
            delay(remaining)

            if (
                activeHostSessionId == ticket.sessionId &&
                SessionCoordinator.snapshot().state == SessionState.CODE_ACTIVE
            ) {
                endHostSession(
                    ticket.sessionId,
                    "Code expired. Tap Share to create a new one."
                )
            }
        }
    }

    private fun sendCode(code: String) {
        val plain = code.filter(Char::isDigit)
        val message =
            "Aaris Remote code: $plain\nOpen Aaris Remote → Connect → START."

        startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, message)
                },
                "Send Aaris Remote code"
            )
        )
    }

    private fun copyCode(code: String) {
        val plain = code.filter(Char::isDigit)
        getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(
                ClipData.newPlainText("Aaris Remote code", plain)
            )
        toast("Code copied")
    }

    private fun endHostSession(
        sessionId: String,
        message: String
    ) {
        if (
            activeHostSessionId != null &&
            activeHostSessionId != sessionId
        ) {
            return
        }

        activeHostSessionId = null
        pendingProjectionSessionId = null
        clearHostUi()
        SessionCoordinator.close(sessionId)
        status.text = message
        setButtonsEnabled(true)

        scope.launch {
            runCatching { gateway.close(sessionId) }
        }
    }

    private fun clearHostUi() {
        hostObserver?.close()
        hostObserver = null

        shareExpiryJob?.cancel()
        shareExpiryJob = null

        shareDialog?.dismiss()
        shareDialog = null

        approvalDialog?.dismiss()
        approvalDialog = null
    }

    private fun isIdleForNewSession(): Boolean {
        return when (SessionCoordinator.snapshot().state) {
            SessionState.IDLE,
            SessionState.SETUP_REQUIRED,
            SessionState.READY,
            SessionState.CLOSED -> true

            else -> false
        }
    }

    private fun refreshIdleUi() {
        if (
            activeHostSessionId == null &&
            SessionCoordinator.snapshot().state == SessionState.CLOSED
        ) {
            SessionCoordinator.prepareReady()
        }

        val idle = isIdleForNewSession()
        setButtonsEnabled(idle)

        if (idle && status.text.isNullOrBlank()) {
            status.text = "Ready"
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

        root.addView(
            TextView(this).apply {
                text = "Aaris Remote"
                textSize = 28f
                setTypeface(typeface, Typeface.BOLD)
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            TextView(this).apply {
                text = "Two taps. One secure session."
                textSize = 15f
                setPadding(0, dp(8), 0, dp(32))
            }
        )

        connectButton = Button(this).apply {
            text = "Connect"
            isAllCaps = false
            textSize = 18f
            setOnClickListener { showConnectDialog() }
        }

        root.addView(
            connectButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(64)
            )
        )

        shareButton = Button(this).apply {
            text = "Share"
            isAllCaps = false
            textSize = 18f
            setOnClickListener { requestShare() }
        }

        root.addView(
            shareButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(64)
            ).apply {
                topMargin = dp(14)
            }
        )

        status = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 14f
            setPadding(0, dp(24), 0, 0)
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
