package com.aaris.remoteassist.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
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
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : Activity() {
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Main
    )
    private val gateway by lazy {
        FirebasePairingGateway(this)
    }

    private lateinit var status: TextView
    private lateinit var connectButton: Button
    private lateinit var shareButton: Button

    private var hostObserver: Closeable? = null
    private var approvalDialogSessionId: String? = null
    private var pendingApprovalSessionId: String? = null
    private var pendingProjectionSessionId: String? = null
    private var shareExpiryJob: Job? = null
    private var activityResumed = false

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
        activityResumed = true

        if (
            prefs.getBoolean(KEY_PENDING_SHARE, false) &&
            PermissionGate.isAccessibilityEnabled(this)
        ) {
            prefs.edit()
                .putBoolean(KEY_PENDING_SHARE, false)
                .apply()

            SessionCoordinator.prepareReady()
            beginShare()
        }

        pendingApprovalSessionId
            ?.let { sessionId ->
                showApproval(sessionId)
            }
    }

    override fun onPause() {
        activityResumed = false
        super.onPause()
    }

    override fun onDestroy() {
        shareExpiryJob?.cancel()
        shareExpiryJob = null
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
        super.onActivityResult(
            requestCode,
            resultCode,
            data
        )

        if (requestCode != REQUEST_MEDIA_PROJECTION) {
            return
        }

        val sessionId = pendingProjectionSessionId
        pendingProjectionSessionId = null

        if (
            sessionId == null ||
            resultCode != RESULT_OK ||
            data == null
        ) {
            if (sessionId != null) {
                scope.launch {
                    runCatching {
                        gateway.close(sessionId)
                    }
                }
                SessionCoordinator.close(sessionId)
            }

            status.text =
                "Screen sharing was not started."
            return
        }

        startForegroundService(
            Intent(
                this,
                ScreenShareService::class.java
            ).apply {
                action = ScreenShareService.ACTION_START
                putExtra(
                    ScreenShareService.EXTRA_SESSION_ID,
                    sessionId
                )
                putExtra(
                    ScreenShareService.EXTRA_RESULT_CODE,
                    resultCode
                )
                putExtra(
                    ScreenShareService.EXTRA_CAPTURE_DATA,
                    data
                )
            }
        )

        status.text =
            "Starting secure connection…"
    }

    private fun showConnectDialog() {
        val density = resources.displayMetrics.density

        val input = EditText(this).apply {
            hint = "000 000"
            gravity = Gravity.CENTER
            inputType = InputType.TYPE_CLASS_NUMBER
            textSize = 24f
            letterSpacing = 0.12f
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_DONE
            setPadding(
                (18 * density).toInt(),
                (10 * density).toInt(),
                (18 * density).toInt(),
                (10 * density).toInt()
            )
        }

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(
                (24 * density).toInt(),
                0,
                (24 * density).toInt(),
                0
            )
            addView(
                input,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
            )
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle("Connect")
            .setMessage(
                "Enter the 6-digit code from your friend."
            )
            .setView(container)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Connect", null)
            .create()

        dialog.setOnShowListener {
            fun submit() {
                val code = PairingCode.normalize(
                    input.text.toString()
                )

                if (code == null) {
                    input.error = "Enter all 6 digits"
                    return
                }

                dialog.dismiss()
                connect(code)
            }

            dialog.getButton(
                AlertDialog.BUTTON_POSITIVE
            ).setOnClickListener {
                submit()
            }

            input.setOnEditorActionListener {
                    _,
                    actionId,
                    _ ->
                if (
                    actionId ==
                    EditorInfo.IME_ACTION_DONE
                ) {
                    submit()
                    true
                } else {
                    false
                }
            }

            input.requestFocus()
            dialog.window?.setSoftInputMode(
                WindowManager.LayoutParams
                    .SOFT_INPUT_STATE_ALWAYS_VISIBLE
            )
        }

        dialog.show()
    }

    private fun requestShare() {
        if (!PermissionGate.isAccessibilityEnabled(this)) {
            prefs.edit()
                .putBoolean(KEY_PENDING_SHARE, true)
                .apply()

            SessionCoordinator.markSetupRequired()
            status.text =
                "One-time setup: turn on Aaris Remote accessibility, then return."

            PermissionGate.openAccessibilitySettings(this)
            return
        }

        SessionCoordinator.prepareReady()
        beginShare()
    }

    private fun beginShare() {
        setButtonsEnabled(false)
        status.text =
            "Creating a secure one-time code…"

        scope.launch {
            if (!prepareForNewSession()) {
                setButtonsEnabled(true)
                return@launch
            }

            runCatching {
                gateway.createShareTicket()
            }.onSuccess { ticket ->
                runCatching {
                    SessionCoordinator.transition(
                        ticket.sessionId,
                        SessionState.CODE_ACTIVE
                    )
                }.onFailure { error ->
                    setButtonsEnabled(true)
                    showBackendError(error)
                    return@onSuccess
                }

                setButtonsEnabled(true)
                observeHostSession(ticket.sessionId)

                val displayCode =
                    PairingCode.display(ticket.code)

                startShareExpiryCountdown(
                    sessionId = ticket.sessionId,
                    displayCode = displayCode,
                    expiresAtEpochMs =
                        ticket.expiresAtEpochMs
                )

                sharePairingCode(
                    displayCode
                )
            }.onFailure {
                setButtonsEnabled(true)
                showBackendError(it)
            }
        }
    }

    private fun connect(code: String) {
        setButtonsEnabled(false)
        status.text =
            "Finding your friend's phone…"

        scope.launch {
            if (!prepareForNewSession()) {
                setButtonsEnabled(true)
                return@launch
            }

            runCatching {
                gateway.redeemCode(code)
            }.onSuccess { request ->
                runCatching {
                    SessionCoordinator.transition(
                        request.sessionId,
                        SessionState.PAIR_PENDING
                    )
                }.onFailure { error ->
                    setButtonsEnabled(true)
                    showBackendError(error)
                    return@onSuccess
                }

                setButtonsEnabled(true)

                startActivity(
                    Intent(
                        this@MainActivity,
                        RemoteControlActivity::class.java
                    ).putExtra(
                        RemoteControlActivity.EXTRA_SESSION_ID,
                        request.sessionId
                    )
                )
            }.onFailure {
                setButtonsEnabled(true)
                showBackendError(it)
            }
        }
    }

    private suspend fun prepareForNewSession(): Boolean {
        val current = SessionCoordinator.snapshot()

        if (
            current.state == SessionState.LIVE ||
            current.state == SessionState.CONNECTING ||
            current.state == SessionState.SCREEN_CONSENT
        ) {
            status.text =
                "A remote-support session is already active."
            return false
        }

        if (
            current.state == SessionState.CODE_ACTIVE ||
            current.state == SessionState.PAIR_PENDING ||
            current.state == SessionState.HOST_APPROVED
        ) {
            shareExpiryJob?.cancel()
            shareExpiryJob = null

            current.sessionId?.let { oldSessionId ->
                runCatching {
                    gateway.close(oldSessionId)
                }
            }

            hostObserver?.close()
            hostObserver = null
            approvalDialogSessionId = null
            pendingApprovalSessionId = null
            SessionCoordinator.reset()
        }

        SessionCoordinator.prepareReady()
        return true
    }

    private fun startShareExpiryCountdown(
        sessionId: String,
        displayCode: String,
        expiresAtEpochMs: Long
    ) {
        shareExpiryJob?.cancel()

        shareExpiryJob = scope.launch {
            while (true) {
                val remainingMs =
                    expiresAtEpochMs -
                        System.currentTimeMillis()

                if (remainingMs <= 0L) {
                    val current =
                        SessionCoordinator
                            .snapshot()

                    if (
                        current.sessionId ==
                        sessionId &&
                        current.state ==
                        SessionState.CODE_ACTIVE
                    ) {
                        runCatching {
                            gateway.close(
                                sessionId
                            )
                        }

                        SessionCoordinator
                            .close(sessionId)

                        hostObserver?.close()
                        hostObserver = null

                        status.text =
                            "Code expired. Tap Share for a new code."
                    }

                    return@launch
                }

                val totalSeconds =
                    (remainingMs + 999L) /
                        1_000L
                val minutes =
                    totalSeconds / 60L
                val seconds =
                    totalSeconds % 60L

                status.text =
                    "Code $displayCode • expires in " +
                        "$minutes:" +
                        seconds
                            .toString()
                            .padStart(2, '0')

                delay(1_000L)
            }
        }
    }

    private fun sharePairingCode(
        displayCode: String
    ) {
        val message = buildString {
            appendLine("Aaris Remote")
            appendLine()
            appendLine(
                "Connection code: $displayCode"
            )
            appendLine()
            append(
                "Open Aaris Remote, tap Connect, and enter this code. "
            )
            append(
                "The code expires shortly and works once."
            )
        }

        val sendIntent = Intent(
            Intent.ACTION_SEND
        ).apply {
            type = "text/plain"
            putExtra(
                Intent.EXTRA_TEXT,
                message
            )
        }

        runCatching {
            startActivity(
                Intent.createChooser(
                    sendIntent,
                    "Send connection code"
                )
            )
        }.onFailure {
            toast(
                "Share this code: $displayCode"
            )
        }
    }

    private fun observeHostSession(
        sessionId: String
    ) {
        hostObserver?.close()

        hostObserver = runCatching {
            gateway.observeSession(
                sessionId = sessionId,
                listener = { backend ->
                    runOnUiThread {
                        when (backend.state) {
                            "PAIR_PENDING" -> {
                                shareExpiryJob?.cancel()
                                shareExpiryJob = null

                                runCatching {
                                    SessionCoordinator
                                        .transition(
                                            sessionId,
                                            SessionState
                                                .PAIR_PENDING
                                        )
                                }

                                if (activityResumed) {
                                    showApproval(sessionId)
                                } else {
                                    pendingApprovalSessionId =
                                        sessionId
                                    status.text =
                                        "Your friend is ready. Return here and tap START."
                                }
                            }

                            "CLOSED" -> {
                                shareExpiryJob?.cancel()
                                shareExpiryJob = null
                                if (
                                    pendingApprovalSessionId ==
                                    sessionId
                                ) {
                                    pendingApprovalSessionId =
                                        null
                                }

                                SessionCoordinator
                                    .close(sessionId)
                                status.text =
                                    "Session ended."
                            }
                        }
                    }
                },
                onError = {
                    runOnUiThread {
                        status.text =
                            "Connection watcher stopped."
                    }
                }
            )
        }.getOrElse {
            showBackendError(it)
            null
        }
    }

    private fun showApproval(
        sessionId: String
    ) {
        if (!activityResumed) {
            pendingApprovalSessionId =
                sessionId
            return
        }

        if (
            approvalDialogSessionId ==
            sessionId
        ) {
            return
        }

        pendingApprovalSessionId = null
        approvalDialogSessionId =
            sessionId

        AlertDialog.Builder(this)
            .setTitle("Your friend is ready")
            .setMessage(
                "Tap START to share and allow remote control now. You can stop the session any time."
            )
            .setPositiveButton("START") {
                    _,
                    _ ->
                approvalDialogSessionId = null
                pendingApprovalSessionId = null
                approveAndRequestScreen(
                    sessionId
                )
            }
            .setNegativeButton("DECLINE") {
                    _,
                    _ ->
                approvalDialogSessionId = null
                pendingApprovalSessionId = null

                scope.launch {
                    runCatching {
                        gateway.close(sessionId)
                    }
                }

                SessionCoordinator.close(
                    sessionId
                )

                status.text =
                    "Connection declined."
            }
            .setOnCancelListener {
                approvalDialogSessionId = null
            }
            .show()
    }

    private fun approveAndRequestScreen(
        sessionId: String
    ) {
        if (
            !PermissionGate
                .isAccessibilityEnabled(this)
        ) {
            scope.launch {
                runCatching {
                    gateway.close(sessionId)
                }
            }

            SessionCoordinator.close(
                sessionId
            )

            status.text =
                "Accessibility was turned off. Tap Share and enable it again."
            return
        }

        status.text =
            "Preparing screen share…"

        scope.launch {
            runCatching {
                gateway.approve(sessionId)
            }.onSuccess {
                runCatching {
                    SessionCoordinator.transition(
                        sessionId,
                        SessionState.HOST_APPROVED
                    )
                }.onFailure { error ->
                    showBackendError(error)
                    return@onSuccess
                }

                pendingProjectionSessionId =
                    sessionId

                val projectionManager =
                    getSystemService(
                        MediaProjectionManager::class.java
                    )

                startActivityForResult(
                    projectionManager
                        .createScreenCaptureIntent(),
                    REQUEST_MEDIA_PROJECTION
                )
            }.onFailure {
                showBackendError(it)
            }
        }
    }

    private fun buildUi(): LinearLayout {
        val density =
            resources.displayMetrics.density

        fun dp(value: Int): Int =
            (value * density).toInt()

        val root = LinearLayout(this).apply {
            orientation =
                LinearLayout.VERTICAL
            gravity =
                Gravity.CENTER_HORIZONTAL
            setPadding(
                dp(24),
                dp(52),
                dp(24),
                dp(24)
            )
        }

        root.addView(
            TextView(this).apply {
                text = "Aaris Remote"
                textSize = 28f
                setTypeface(
                    typeface,
                    Typeface.BOLD
                )
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            TextView(this).apply {
                text =
                    "Remote help in two taps"
                textSize = 15f
                gravity = Gravity.CENTER
                setPadding(
                    0,
                    dp(8),
                    0,
                    dp(26)
                )
            }
        )

        val actions = LinearLayout(this).apply {
            orientation =
                LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        connectButton =
            Button(this).apply {
                text = "Connect"
                isAllCaps = false
                setOnClickListener {
                    showConnectDialog()
                }
            }

        shareButton =
            Button(this).apply {
                text = "Share"
                isAllCaps = false
                setOnClickListener {
                    requestShare()
                }
            }

        actions.addView(
            connectButton,
            LinearLayout.LayoutParams(
                0,
                dp(60),
                1f
            ).apply {
                marginEnd = dp(6)
            }
        )

        actions.addView(
            shareButton,
            LinearLayout.LayoutParams(
                0,
                dp(60),
                1f
            ).apply {
                marginStart = dp(6)
            }
        )

        root.addView(
            actions,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        status = TextView(this).apply {
            text =
                "Choose Connect or Share."
            gravity = Gravity.CENTER
            textSize = 14f
            setPadding(
                0,
                dp(24),
                0,
                0
            )
        }

        root.addView(status)
        return root
    }

    private fun setButtonsEnabled(
        enabled: Boolean
    ) {
        connectButton.isEnabled =
            enabled
        shareButton.isEnabled =
            enabled
    }

    private fun showBackendError(
        error: Throwable
    ) {
        status.text =
            error.message
                ?: "Could not connect. Try again."
    }

    private fun toast(message: String) {
        Toast.makeText(
            this,
            message,
            Toast.LENGTH_SHORT
        ).show()
    }

    companion object {
        private const val KEY_PENDING_SHARE =
            "pending_share"
        private const val REQUEST_MEDIA_PROJECTION =
            7001
    }
}
