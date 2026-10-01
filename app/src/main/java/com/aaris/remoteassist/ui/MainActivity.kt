package com.aaris.remoteassist.ui

import android.Manifest
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.accessibility.PermissionGate
import com.aaris.remoteassist.capture.ScreenShareService
import com.aaris.remoteassist.pairing.BackendSession
import com.aaris.remoteassist.pairing.BackendSessionCloser
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.pairing.PairingCode
import com.aaris.remoteassist.pairing.PairingLink
import com.aaris.remoteassist.pairing.PairingShareText
import com.aaris.remoteassist.pairing.ShareTicket
import com.aaris.remoteassist.session.HostBackendStateSync
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionState
import java.io.Closeable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val gateway by lazy { FirebasePairingGateway(this) }

    private lateinit var status: TextView
    private lateinit var statusProgress: ProgressBar
    private lateinit var connectButton: Button
    private lateinit var shareButton: Button

    private var hostObserver: Closeable? = null
    private var shareDialog: AlertDialog? = null
    private var approvalDialog: AlertDialog? = null
    private var sessionDeadlineJob: Job? = null
    private var activeHostSessionId: String? = null
    private var pendingProjectionSessionId: String? = null
    private var pendingNotificationSessionId: String? = null
    private var hostStartInFlight = false
    private var accessibilityReadyJob: Job? = null

    private val prefs by lazy {
        getSharedPreferences("setup", Context.MODE_PRIVATE)
    }

    private val screenCaptureLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { result ->
            handleProjectionResult(
                result.resultCode,
                result.data
            )
        }

    private val remoteControlLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { result ->
            val message = result.data?.getStringExtra(
                RemoteControlActivity.EXTRA_RESULT_MESSAGE
            )

            if (
                activeHostSessionId == null &&
                SessionCoordinator.snapshot().state == SessionState.CLOSED
            ) {
                SessionCoordinator.prepareReady()
            }

            refreshIdleUi()
            if (isIdleForNewSession()) {
                status.text = message ?: "Ready"
            }
        }

    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission()
        ) {
            val sessionId = pendingNotificationSessionId
            pendingNotificationSessionId = null
            prefs.edit()
                .putBoolean(KEY_NOTIFICATION_PERMISSION_ASKED, true)
                .apply()

            if (
                sessionId != null &&
                activeHostSessionId == sessionId
            ) {
                continueHostStart(
                    sessionId = sessionId,
                    skipNotificationPrompt = true
                )
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())
        installBackHandler()

        val restoredHostSession = recoverPersistedHostSession()
        if (!restoredHostSession) {
            if (PermissionGate.isAccessibilityEnabled(this)) {
                SessionCoordinator.prepareReady()
            } else {
                SessionCoordinator.markSetupRequired()
            }
        }
        refreshIdleUi()
        handleIncomingJoin(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingJoin(intent)
    }

    private fun installBackHandler() {
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    val id = activeHostSessionId
                    val state =
                        SessionCoordinator.snapshot().state

                    if (
                        id != null &&
                        state != SessionState.LIVE
                    ) {
                        cancelPendingHostAndFinish(id)
                        return
                    }

                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                }
            }
        )
    }

    override fun onResume() {
        super.onResume()

        if (hasFreshPendingShare()) {
            if (activeHostSessionId == null) {
                if (PermissionGate.isAccessibilityEnabled(this)) {
                    startShareWhenAccessibilityReady()
                    return
                }

                status.text =
                    "Turn on Aaris Remote once. Share starts automatically when you return."
            }
        } else {
            clearPendingShareRequest()
        }

        val pendingStart = prefs.getString(
            KEY_PENDING_HOST_START_SESSION,
            null
        )

        if (
            pendingStart != null &&
            activeHostSessionId == pendingStart &&
            PermissionGate.isAccessibilityEnabled(this)
        ) {
            val current = SessionCoordinator.snapshot()
            if (current.sessionId == pendingStart) {
                when (current.state) {
                    SessionState.PAIR_PENDING -> {
                        continueHostStart(pendingStart)
                        return
                    }

                    SessionState.HOST_APPROVED -> {
                        continueApprovedHostStart(pendingStart)
                        return
                    }

                    else -> Unit
                }
            }

            status.text = "Finishing secure setup…"
        }

        refreshIdleUi()
    }

    override fun onDestroy() {
        accessibilityReadyJob?.cancel()
        accessibilityReadyJob = null
        hostObserver?.close()
        hostObserver = null
        sessionDeadlineJob?.cancel()
        sessionDeadlineJob = null
        shareDialog?.dismiss()
        shareDialog = null
        approvalDialog?.dismiss()
        approvalDialog = null
        scope.cancel()
        super.onDestroy()
    }

    private fun handleProjectionResult(
        resultCode: Int,
        data: Intent?
    ) {
        val sessionId = pendingProjectionSessionId
            ?: prefs.getString(KEY_PENDING_PROJECTION_SESSION, null)
        pendingProjectionSessionId = null
        prefs.edit()
            .remove(KEY_PENDING_PROJECTION_SESSION)
            .apply()

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

        connectivityBlockMessage()?.let { message ->
            status.text = message
            return
        }

        rememberPendingShare()

        if (!PermissionGate.isAccessibilityEnabled(this)) {
            SessionCoordinator.markSetupRequired()
            status.text =
                "Turn on Aaris Remote once. Share starts automatically when you return."
            PermissionGate.openAccessibilitySettings(this)
            return
        }

        startShareWhenAccessibilityReady()
    }

    private fun startShareWhenAccessibilityReady() {
        if (
            activeHostSessionId != null ||
            !isIdleForNewSession()
        ) {
            return
        }

        if (!PermissionGate.isAccessibilityEnabled(this)) {
            SessionCoordinator.markSetupRequired()
            status.text =
                "Turn on Aaris Remote once. Share starts automatically when you return."
            return
        }

        accessibilityReadyJob?.cancel()
        setButtonsEnabled(false)
        status.text = "Finishing Accessibility setup…"

        accessibilityReadyJob = scope.launch {
            val deadline =
                SystemClock.elapsedRealtime() +
                    ACCESSIBILITY_SERVICE_READY_TIMEOUT_MS

            while (
                isActive &&
                !AssistAccessibilityService.isConnected() &&
                SystemClock.elapsedRealtime() < deadline
            ) {
                delay(ACCESSIBILITY_SERVICE_READY_POLL_MS)
            }

            accessibilityReadyJob = null

            if (!PermissionGate.isAccessibilityEnabled(this@MainActivity)) {
                SessionCoordinator.markSetupRequired()
                setButtonsEnabled(true)
                status.text =
                    "Accessibility was turned off. Tap Share to continue."
                return@launch
            }

            if (!AssistAccessibilityService.isConnected()) {
                setButtonsEnabled(true)
                status.text =
                    "Accessibility is on but still starting. Tap Share to retry."
                return@launch
            }

            clearPendingShareRequest()

            connectivityBlockMessage()?.let { message ->
                setButtonsEnabled(true)
                status.text = message
                return@launch
            }

            SessionCoordinator.prepareReady()
            beginShare()
        }
    }

    private fun rememberPendingShare() {
        prefs.edit()
            .putBoolean(
                KEY_PENDING_SHARE_AFTER_ACCESSIBILITY,
                true
            )
            .putLong(
                KEY_PENDING_SHARE_REQUESTED_AT,
                System.currentTimeMillis()
            )
            .apply()
    }

    private fun hasFreshPendingShare(): Boolean {
        if (
            !prefs.getBoolean(
                KEY_PENDING_SHARE_AFTER_ACCESSIBILITY,
                false
            )
        ) {
            return false
        }

        val requestedAt = prefs.getLong(
            KEY_PENDING_SHARE_REQUESTED_AT,
            0L
        )
        if (requestedAt <= 0L) return false

        val age = System.currentTimeMillis() - requestedAt
        return age in 0..PENDING_SHARE_MAX_AGE_MS
    }

    private fun clearPendingShareRequest() {
        prefs.edit()
            .remove(KEY_PENDING_SHARE_AFTER_ACCESSIBILITY)
            .remove(KEY_PENDING_SHARE_REQUESTED_AT)
            .apply()
    }

    private fun beginShare() {
        clearHostUi()
        setButtonsEnabled(false)
        status.text = "Creating secure one-time code…"

        scope.launch {
            runCatching { gateway.createShareTicket() }
                .onSuccess { ticket ->
                    activeHostSessionId = ticket.sessionId
                    persistHostTicket(ticket)

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
                    scheduleSessionDeadline(
                        sessionId = ticket.sessionId,
                        deadlineAtEpochMs = ticket.expiresAtEpochMs,
                        backendState = "CODE_ACTIVE"
                    )
                    sendCode(ticket.code)
                }
                .onFailure {
                    setButtonsEnabled(true)
                    showBackendError(it)
                }
        }
    }

    private fun handleIncomingJoin(source: Intent?) {
        val code = PairingLink.parse(source?.dataString) ?: return
        source?.setData(null)
        showConnectDialog(code)
    }

    private fun showConnectDialog(initialCode: String? = null) {
        if (!isIdleForNewSession()) {
            toast("Finish the current session first")
            return
        }

        val suggestedCode = initialCode ?: pairingCodeFromClipboard()
        val input = EditText(this).apply {
            hint = "0000 0000 0000"
            gravity = Gravity.CENTER
            inputType = InputType.TYPE_CLASS_NUMBER
            textSize = 24f
            letterSpacing = 0.12f
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_DONE
        }

        suggestedCode?.let { code ->
            input.setText(code)
            input.setSelection(input.text.length)
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle("Connect")
            .setMessage("Enter the 12-digit one-time code from your friend.")
            .setView(input)
            .setPositiveButton("START", null)
            .setNegativeButton("CANCEL", null)
            .create()

        fun submit() {
            val code = PairingCode.normalize(input.text.toString())
            if (code == null) {
                input.error = "Enter the 12-digit code"
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

    private fun pairingCodeFromClipboard(): String? {
        val clipboard = getSystemService(ClipboardManager::class.java)
        if (!clipboard.hasPrimaryClip()) return null

        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null

        val raw = clip.getItemAt(0)
            .coerceToText(this)
            ?.toString()
            ?: return null

        return PairingCode.extract(raw)
    }

    private fun connect(code: String) {
        clearPendingShareRequest()

        connectivityBlockMessage()?.let { message ->
            status.text = message
            return
        }

        SessionCoordinator.prepareReady()
        setButtonsEnabled(false)
        status.text = "Finding your friend's phone…"

        scope.launch {
            val request = runCatching {
                gateway.redeemCode(code)
            }.getOrElse {
                setButtonsEnabled(true)
                showBackendError(it)
                return@launch
            }

            val localStarted = runCatching {
                SessionCoordinator.transition(
                    request.sessionId,
                    SessionState.PAIR_PENDING
                )
            }.isSuccess

            if (!localStarted) {
                BackendSessionCloser.close(
                    this@MainActivity,
                    request.sessionId
                )
                SessionCoordinator.close(request.sessionId)
                setButtonsEnabled(true)
                status.text = "Could not start this connection. Try again."
                return@launch
            }

            status.text = "Connection request sent."
            remoteControlLauncher.launch(
                Intent(
                    this@MainActivity,
                    RemoteControlActivity::class.java
                ).putExtra(
                    RemoteControlActivity.EXTRA_SESSION_ID,
                    request.sessionId
                )
            )
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

                        updateHostDeadline(
                            sessionId,
                            backend
                        )

                        val recovered = reconcileHostState(
                            sessionId,
                            backend.state
                        ) ?: return@runOnUiThread

                        when (backend.state) {
                            "CODE_ACTIVE" -> {
                                status.text = "Share code is still active."
                                if (recovered) {
                                    val ticket =
                                        persistedShareTicket(sessionId)
                                    if (ticket == null) {
                                        endHostSession(
                                            sessionId,
                                            "Share code expired. Tap Share again."
                                        )
                                        return@runOnUiThread
                                    }
                                    showShareCode(ticket)
                                }
                            }

                            "PAIR_PENDING" -> {
                                clearPersistedShareCode()
                                shareDialog?.dismiss()
                                shareDialog = null

                                val pendingStart = prefs.getString(
                                    KEY_PENDING_HOST_START_SESSION,
                                    null
                                )
                                if (pendingStart == sessionId) {
                                    if (
                                        PermissionGate.isAccessibilityEnabled(
                                            this@MainActivity
                                        )
                                    ) {
                                        continueHostStart(sessionId)
                                    } else {
                                        status.text =
                                            "Turn on Aaris Remote once. Setup resumes automatically."
                                    }
                                } else {
                                    showApproval(sessionId)
                                }
                            }

                            "HOST_APPROVED" -> {
                                clearPersistedShareCode()
                                status.text = "Waiting for screen permission…"

                                val pendingStart = prefs.getString(
                                    KEY_PENDING_HOST_START_SESSION,
                                    null
                                )
                                if (pendingStart == sessionId) {
                                    if (
                                        PermissionGate.isAccessibilityEnabled(
                                            this@MainActivity
                                        )
                                    ) {
                                        if (hostStartInFlight) {
                                            status.text =
                                                "Preparing screen share…"
                                        } else {
                                            continueApprovedHostStart(sessionId)
                                        }
                                    } else {
                                        status.text =
                                            "Turn on Aaris Remote once. Setup resumes automatically."
                                    }
                                } else if (
                                    recovered &&
                                    prefs.getString(
                                        KEY_PENDING_PROJECTION_SESSION,
                                        null
                                    ) != sessionId
                                ) {
                                    showResumeScreenShare(sessionId)
                                }
                            }

                            "SCREEN_READY",
                            "CONNECTING" ->
                                status.text = "Connecting phones…"

                            "LIVE" ->
                                status.text =
                                    "Remote support is LIVE. Tap STOP • SHARING any time."

                            "CLOSED" -> {
                                BackendSessionCloser.close(
                                    this@MainActivity,
                                    sessionId
                                )
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
                            endHostSession(
                                sessionId,
                                "Connection lost. Tap Share to try again."
                            )
                        }
                    }
                }
            )
        }.getOrElse {
            showBackendError(it)
            null
        }
    }

    private fun reconcileHostState(
        sessionId: String,
        backendState: String
    ): Boolean? {
        val current = SessionCoordinator.snapshot()
        val localSessionIsActive =
            current.sessionId == sessionId &&
                when (current.state) {
                    SessionState.CODE_ACTIVE,
                    SessionState.PAIR_PENDING,
                    SessionState.HOST_APPROVED,
                    SessionState.SCREEN_CONSENT,
                    SessionState.CONNECTING,
                    SessionState.LIVE -> true

                    else -> false
                }

        if (localSessionIsActive) {
            return runCatching {
                HostBackendStateSync.forwardTransitions(
                    current.state,
                    backendState
                ).forEach { next ->
                    SessionCoordinator.transition(
                        sessionId,
                        next
                    )
                }
                false
            }.getOrElse {
                endHostSession(
                    sessionId,
                    "Could not synchronize the session. Tap Share again."
                )
                null
            }
        }

        val target = when (backendState) {
            "CODE_ACTIVE" -> SessionState.CODE_ACTIVE
            "PAIR_PENDING" -> SessionState.PAIR_PENDING
            "HOST_APPROVED" -> SessionState.HOST_APPROVED

            "SCREEN_READY",
            "CONNECTING",
            "LIVE" -> {
                endHostSession(
                    sessionId,
                    "Session was interrupted. Tap Share to start again."
                )
                return null
            }

            else -> return false
        }

        return runCatching {
            SessionCoordinator.reset()
            SessionCoordinator.prepareReady()
            SessionCoordinator.transition(
                sessionId,
                SessionState.CODE_ACTIVE
            )

            if (
                target == SessionState.PAIR_PENDING ||
                target == SessionState.HOST_APPROVED
            ) {
                SessionCoordinator.transition(
                    sessionId,
                    SessionState.PAIR_PENDING
                )
            }

            if (target == SessionState.HOST_APPROVED) {
                SessionCoordinator.transition(
                    sessionId,
                    SessionState.HOST_APPROVED
                )
            }
            true
        }.getOrElse {
            endHostSession(
                sessionId,
                "Could not restore the session. Tap Share again."
            )
            null
        }
    }

    private fun showShareCode(ticket: ShareTicket) {
        shareDialog?.dismiss()

        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        val codeView = TextView(this).apply {
            text = PairingCode.display(ticket.code)
            textSize = 28f
            gravity = Gravity.CENTER
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            letterSpacing = 0.08f
            setTextColor(AarisUi.TEXT_PRIMARY)
            background = AarisUi.panel(
                context = this@MainActivity,
                fill = AarisUi.SURFACE_MUTED,
                radiusDp = 18,
                strokeColor = AarisUi.BORDER
            )
            setPadding(dp(24), dp(20), dp(24), dp(20))
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle("Share this code")
            .setMessage("It works once and expires in 5 minutes.")
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
                continueHostStart(sessionId)
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

    private fun showResumeScreenShare(sessionId: String) {
        if (approvalDialog?.isShowing == true) return

        val dialog = AlertDialog.Builder(this)
            .setTitle("Continue remote support?")
            .setMessage(
                "The app restarted before screen sharing began. Tap START to continue securely."
            )
            .setPositiveButton("START") { _, _ ->
                approvalDialog = null
                continueApprovedHostStart(sessionId)
            }
            .setNegativeButton("END") { _, _ ->
                approvalDialog = null
                endHostSession(
                    sessionId,
                    "Session ended."
                )
            }
            .setCancelable(false)
            .create()

        approvalDialog = dialog
        dialog.show()
    }

    private fun continueHostStart(
        sessionId: String,
        skipNotificationPrompt: Boolean = false
    ) {
        if (activeHostSessionId != sessionId) return

        if (
            !skipNotificationPrompt &&
            shouldAskNotificationPermission()
        ) {
            pendingNotificationSessionId = sessionId
            status.text =
                "Allow session alerts so STOP stays easy to reach."
            notificationPermissionLauncher.launch(
                Manifest.permission.POST_NOTIFICATIONS
            )
            return
        }

        if (!PermissionGate.isAccessibilityEnabled(this)) {
            prefs.edit()
                .putString(
                    KEY_PENDING_HOST_START_SESSION,
                    sessionId
                )
                .apply()
            status.text =
                "Turn on Aaris Remote once. Setup resumes automatically."
            PermissionGate.openAccessibilitySettings(this)
            return
        }

        approveAndRequestScreen(sessionId)
    }

    private fun shouldAskNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        if (
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }

        return !prefs.getBoolean(
            KEY_NOTIFICATION_PERMISSION_ASKED,
            false
        )
    }

    private fun continueApprovedHostStart(sessionId: String) {
        if (activeHostSessionId != sessionId) return

        if (!PermissionGate.isAccessibilityEnabled(this)) {
            prefs.edit()
                .putString(
                    KEY_PENDING_HOST_START_SESSION,
                    sessionId
                )
                .apply()
            status.text =
                "Turn on Aaris Remote once. Setup resumes automatically."
            PermissionGate.openAccessibilitySettings(this)
            return
        }

        prefs.edit()
            .remove(KEY_PENDING_HOST_START_SESSION)
            .apply()
        requestScreenPermission(sessionId)
    }

    private fun approveAndRequestScreen(sessionId: String) {
        if (hostStartInFlight) return

        if (!PermissionGate.isAccessibilityEnabled(this)) {
            continueHostStart(sessionId)
            return
        }

        hostStartInFlight = true
        status.text = "Preparing screen share…"

        scope.launch {
            runCatching { gateway.approve(sessionId) }
                .onSuccess {
                    val shouldRequestScreen = runCatching {
                        val current = SessionCoordinator.snapshot()
                        require(current.sessionId == sessionId)

                        when (current.state) {
                            SessionState.PAIR_PENDING -> {
                                SessionCoordinator.transition(
                                    sessionId,
                                    SessionState.HOST_APPROVED
                                )
                                true
                            }

                            SessionState.HOST_APPROVED -> true

                            SessionState.SCREEN_CONSENT,
                            SessionState.CONNECTING -> false

                            else -> error(
                                "Unexpected local state: ${current.state}"
                            )
                        }
                    }.getOrElse {
                        hostStartInFlight = false
                        endHostSession(
                            sessionId,
                            "Session state changed. Try again."
                        )
                        return@onSuccess
                    }

                    hostStartInFlight = false
                    prefs.edit()
                        .remove(KEY_PENDING_HOST_START_SESSION)
                        .apply()

                    if (shouldRequestScreen) {
                        requestScreenPermission(sessionId)
                    }
                }
                .onFailure {
                    hostStartInFlight = false
                    endHostSession(
                        sessionId,
                        it.message ?: "Could not approve this connection."
                    )
                }
        }
    }

    private fun requestScreenPermission(sessionId: String) {
        if (!PermissionGate.isAccessibilityEnabled(this)) {
            continueApprovedHostStart(sessionId)
            return
        }

        prefs.edit()
            .remove(KEY_PENDING_HOST_START_SESSION)
            .apply()

        if (
            pendingProjectionSessionId == sessionId ||
            prefs.getString(
                KEY_PENDING_PROJECTION_SESSION,
                null
            ) == sessionId
        ) {
            status.text = "Waiting for screen permission…"
            return
        }

        val current = SessionCoordinator.snapshot()
        if (
            current.sessionId != sessionId ||
            current.state != SessionState.HOST_APPROVED
        ) {
            endHostSession(
                sessionId,
                "Session state changed. Tap Share again."
            )
            return
        }

        pendingProjectionSessionId = sessionId
        prefs.edit()
            .putString(
                KEY_PENDING_PROJECTION_SESSION,
                sessionId
            )
            .apply()

        val projectionManager =
            getSystemService(MediaProjectionManager::class.java)
        val captureIntent =
            if (Build.VERSION.SDK_INT >= 34) {
                projectionManager.createScreenCaptureIntent(
                    MediaProjectionConfig.createConfigForDefaultDisplay()
                )
            } else {
                projectionManager.createScreenCaptureIntent()
            }

        screenCaptureLauncher.launch(captureIntent)
    }

    private fun updateHostDeadline(
        sessionId: String,
        backend: BackendSession
    ) {
        if (
            backend.state == "LIVE" ||
            backend.state == "CLOSED"
        ) {
            sessionDeadlineJob?.cancel()
            sessionDeadlineJob = null
            return
        }

        val deadline = backend.deadlineAtEpochMs ?: return
        scheduleSessionDeadline(
            sessionId = sessionId,
            deadlineAtEpochMs = deadline,
            backendState = backend.state
        )
    }

    private fun scheduleSessionDeadline(
        sessionId: String,
        deadlineAtEpochMs: Long,
        backendState: String
    ) {
        sessionDeadlineJob?.cancel()
        sessionDeadlineJob = scope.launch {
            val remaining =
                (
                    deadlineAtEpochMs -
                        System.currentTimeMillis() +
                        CLIENT_DEADLINE_GRACE_MS
                ).coerceAtLeast(0L)
            delay(remaining)

            if (activeHostSessionId != sessionId) {
                return@launch
            }

            val localState = SessionCoordinator.snapshot().state
            val stillInExpiredPhase = when (backendState) {
                "CODE_ACTIVE" ->
                    localState == SessionState.CODE_ACTIVE

                "PAIR_PENDING" ->
                    localState == SessionState.PAIR_PENDING

                "HOST_APPROVED",
                "SCREEN_READY",
                "CONNECTING" ->
                    localState == SessionState.HOST_APPROVED ||
                        localState == SessionState.SCREEN_CONSENT ||
                        localState == SessionState.CONNECTING

                else -> false
            }

            if (!stillInExpiredPhase) {
                return@launch
            }

            val message = when (backendState) {
                "CODE_ACTIVE" ->
                    "Share code expired. Tap Share to create a new code."

                "PAIR_PENDING" ->
                    "Connection request expired. Tap Share to try again."

                else ->
                    "Connection setup expired. Tap Share to try again."
            }

            endHostSession(
                sessionId,
                message
            )
        }
    }

    private fun sendCode(code: String) {
        val message = PairingShareText.build(code)
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(
                Intent.EXTRA_SUBJECT,
                "Aaris Remote support code"
            )
            putExtra(Intent.EXTRA_TEXT, message)
        }

        // Launch the system chooser directly. Pre-resolving ACTION_SEND can
        // produce false negatives on some OEM/package-visibility combinations.
        // If the chooser cannot be opened, keep the same live session and copy
        // the complete invite instead of forcing the user through setup again.
        val launched = runCatching {
            startActivity(
                Intent.createChooser(
                    shareIntent,
                    "Send Aaris Remote code"
                )
            )
        }.isSuccess

        if (!launched) {
            getSystemService(ClipboardManager::class.java)
                .setPrimaryClip(
                    ClipData.newPlainText(
                        "Aaris Remote invite",
                        message
                    )
                )
            status.text =
                "No sharing app was available. Invite copied."
            toast("Invite copied")
        }
    }

    private fun copyCode(code: String) {
        val plain = code.filter(Char::isDigit)
        getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(
                ClipData.newPlainText("Aaris Remote code", plain)
            )
        toast("Code copied")
    }

    private fun persistHostTicket(ticket: ShareTicket) {
        prefs.edit()
            .putString(KEY_ACTIVE_HOST_SESSION, ticket.sessionId)
            .putString(KEY_ACTIVE_HOST_CODE, ticket.code)
            .putLong(
                KEY_ACTIVE_HOST_EXPIRES_AT,
                ticket.expiresAtEpochMs
            )
            .apply()
    }

    private fun persistedShareTicket(sessionId: String): ShareTicket? {
        val code = prefs.getString(KEY_ACTIVE_HOST_CODE, null)
            ?: return null
        val expiresAt = prefs.getLong(
            KEY_ACTIVE_HOST_EXPIRES_AT,
            0L
        )
        if (expiresAt <= System.currentTimeMillis()) return null

        return runCatching {
            PairingCode.normalize(code)
                ?.let {
                    ShareTicket(
                        sessionId = sessionId,
                        code = it,
                        expiresAtEpochMs = expiresAt
                    )
                }
        }.getOrNull()
    }

    private fun clearPersistedShareCode() {
        prefs.edit()
            .remove(KEY_ACTIVE_HOST_CODE)
            .remove(KEY_ACTIVE_HOST_EXPIRES_AT)
            .apply()
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
        pendingNotificationSessionId = null
        hostStartInFlight = false
        clearHostUi()
        SessionCoordinator.close(sessionId)
        status.text = message
        setButtonsEnabled(true)

        BackendSessionCloser.close(this, sessionId)
    }

    private fun clearHostUi() {
        activeHostSessionId = null
        pendingProjectionSessionId = null
        pendingNotificationSessionId = null
        hostStartInFlight = false
        prefs.edit()
            .remove(KEY_ACTIVE_HOST_SESSION)
            .remove(KEY_PENDING_PROJECTION_SESSION)
            .remove(KEY_PENDING_HOST_START_SESSION)
            .remove(KEY_ACTIVE_HOST_CODE)
            .remove(KEY_ACTIVE_HOST_EXPIRES_AT)
            .apply()

        hostObserver?.close()
        hostObserver = null

        sessionDeadlineJob?.cancel()
        sessionDeadlineJob = null

        shareDialog?.dismiss()
        shareDialog = null

        approvalDialog?.dismiss()
        approvalDialog = null
    }

    private fun recoverPersistedHostSession(): Boolean {
        val sessionId = prefs.getString(
            KEY_ACTIVE_HOST_SESSION,
            null
        ) ?: return false

        activeHostSessionId = sessionId
        pendingProjectionSessionId = prefs.getString(
            KEY_PENDING_PROJECTION_SESSION,
            null
        )
        setButtonsEnabled(false)
        status.text = "Restoring secure session…"
        observeHostSession(sessionId)
        return true
    }

    private fun cancelPendingHostAndFinish(sessionId: String) {
        setButtonsEnabled(false)
        status.text = "Cancelling share session…"

        BackendSessionCloser.close(this, sessionId)
        SessionCoordinator.close(sessionId)
        clearHostUi()
        finish()
    }

    private fun isIdleForNewSession(): Boolean {
        if (activeHostSessionId != null) return false

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
        } else if (!idle && status.text.isNullOrBlank()) {
            status.text = when (SessionCoordinator.snapshot().state) {
                SessionState.LIVE ->
                    "Remote support is LIVE. Tap STOP • SHARING any time."
                SessionState.CONNECTING ->
                    "Connecting phones…"
                SessionState.PAIR_PENDING ->
                    "Waiting for approval…"
                SessionState.CODE_ACTIVE ->
                    "Share code is active."
                else ->
                    "Session in progress…"
            }
        }
    }

    private fun buildUi(): LinearLayout {
        fun dp(value: Int) = AarisUi.dp(this, value)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(22), dp(30), dp(22), dp(22))
            setBackgroundColor(AarisUi.CANVAS)
        }

        val brandRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val mark = TextView(this).apply {
            text = "AR"
            gravity = Gravity.CENTER
            textSize = 16f
            setTextColor(AarisUi.ON_PRIMARY)
            typeface = Typeface.create(
                "sans-serif-medium",
                Typeface.NORMAL
            )
            background = AarisUi.panel(
                context = this@MainActivity,
                fill = AarisUi.PRIMARY,
                radiusDp = 16
            )
        }
        brandRow.addView(
            mark,
            LinearLayout.LayoutParams(
                dp(48),
                dp(48)
            )
        )

        val brandText = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), 0, 0, 0)
        }
        brandText.addView(
            TextView(this).apply {
                text = "Aaris Remote"
                textSize = 21f
                setTextColor(AarisUi.TEXT_PRIMARY)
                typeface = Typeface.create(
                    "sans-serif-medium",
                    Typeface.NORMAL
                )
            }
        )
        brandText.addView(
            TextView(this).apply {
                text = "Secure remote support"
                textSize = 13f
                setTextColor(AarisUi.TEXT_SECONDARY)
            }
        )
        brandRow.addView(
            brandText,
            LinearLayout.LayoutParams(
                0,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1f
            )
        )

        root.addView(
            brandRow,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            TextView(this).apply {
                text = "Help someone. Stay in control."
                textSize = 30f
                setTextColor(AarisUi.TEXT_PRIMARY)
                typeface = Typeface.create(
                    "sans-serif-medium",
                    Typeface.NORMAL
                )
                setPadding(0, dp(34), 0, 0)
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            TextView(this).apply {
                text =
                    "One-time pairing, visible sharing, and a STOP button that stays with you."
                textSize = 15f
                setTextColor(AarisUi.TEXT_SECONDARY)
                setLineSpacing(0f, 1.15f)
                setPadding(0, dp(10), 0, 0)
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(28), 0, 0)
        }

        connectButton = Button(this).apply {
            text = "Connect"
            contentDescription =
                "Connect to a friend's Aaris Remote session"
            AarisUi.secondaryButton(this)
            setOnClickListener {
                AarisUi.haptic(this)
                showConnectDialog()
            }
        }

        shareButton = Button(this).apply {
            text = "Share"
            contentDescription =
                "Share this phone for remote support"
            AarisUi.primaryButton(this)
            setOnClickListener {
                AarisUi.haptic(this)
                requestShare()
            }
        }

        actions.addView(
            connectButton,
            LinearLayout.LayoutParams(
                0,
                dp(64),
                1f
            ).apply {
                marginEnd = dp(7)
            }
        )

        actions.addView(
            shareButton,
            LinearLayout.LayoutParams(
                0,
                dp(64),
                1f
            ).apply {
                marginStart = dp(7)
            }
        )

        root.addView(
            actions,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        val statusCard = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = AarisUi.panel(
                context = this@MainActivity,
                fill = AarisUi.SURFACE,
                radiusDp = 18,
                strokeColor = AarisUi.BORDER
            )
            setPadding(dp(16), dp(15), dp(16), dp(15))
            elevation = dp(1).toFloat()
        }

        statusProgress = ProgressBar(this).apply {
            isIndeterminate = true
            visibility = View.GONE
            AarisUi.tintProgress(this, AarisUi.PRIMARY)
        }
        statusCard.addView(
            statusProgress,
            LinearLayout.LayoutParams(
                dp(22),
                dp(22)
            ).apply {
                marginEnd = dp(12)
            }
        )

        status = TextView(this).apply {
            text = "Ready"
            textSize = 14f
            setTextColor(AarisUi.TEXT_PRIMARY)
            typeface = Typeface.create(
                "sans-serif-medium",
                Typeface.NORMAL
            )
            addTextChangedListener(
                object : TextWatcher {
                    override fun beforeTextChanged(
                        s: CharSequence?,
                        start: Int,
                        count: Int,
                        after: Int
                    ) = Unit

                    override fun onTextChanged(
                        s: CharSequence?,
                        start: Int,
                        before: Int,
                        count: Int
                    ) = Unit

                    override fun afterTextChanged(s: Editable?) {
                        updateStatusChrome(
                            s?.toString().orEmpty()
                        )
                    }
                }
            )
        }

        statusCard.addView(
            status,
            LinearLayout.LayoutParams(
                0,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1f
            )
        )

        root.addView(
            statusCard,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(22)
            }
        )

        root.addView(
            TextView(this).apply {
                text =
                    "Protected by explicit approval • one-time code • screen-share consent"
                textSize = 12f
                gravity = Gravity.CENTER
                setTextColor(AarisUi.TEXT_TERTIARY)
                setPadding(dp(8), dp(18), dp(8), 0)
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        @Suppress("DEPRECATION")
        root.setOnApplyWindowInsetsListener { view, insets ->
            view.setPadding(
                dp(22) + insets.systemWindowInsetLeft,
                dp(30) + insets.systemWindowInsetTop,
                dp(22) + insets.systemWindowInsetRight,
                dp(22) + insets.systemWindowInsetBottom
            )
            insets
        }
        root.requestApplyInsets()

        updateStatusChrome(status.text.toString())
        return root
    }

    private fun updateStatusChrome(message: String) {
        if (!::statusProgress.isInitialized) return

        val value = message.lowercase()
        val busy = listOf(
            "creating",
            "finding",
            "waiting",
            "preparing",
            "starting",
            "connecting",
            "restoring",
            "finishing",
            "cancelling",
            "ending"
        ).any(value::contains)

        statusProgress.visibility =
            if (busy) View.VISIBLE else View.GONE

        val error = listOf(
            "could not",
            "expired",
            "lost",
            "cancelled",
            "declined",
            "not started",
            "ended",
            "no internet",
            "unavailable"
        ).any(value::contains)

        status.setTextColor(
            if (error) AarisUi.DANGER else AarisUi.TEXT_PRIMARY
        )
    }

    private fun setButtonsEnabled(enabled: Boolean) {
        connectButton.isEnabled = enabled
        shareButton.isEnabled = enabled
        connectButton.alpha = if (enabled) 1f else 0.58f
        shareButton.alpha = if (enabled) 1f else 0.58f
    }

    private fun showBackendError(error: Throwable) {
        val detail = generateSequence(error) {
            it.cause
        }
            .mapNotNull { it.message }
            .joinToString(" ")
            .lowercase()

        status.text = when {
            "wrong firebase project" in detail ->
                "This build is connected to the wrong Aaris Remote service."

            "not configured" in detail ->
                "Aaris Remote service is not configured on this build."

            "permission denied" in detail ||
                "permission_denied" in detail ->
                "Aaris Remote service setup needs attention. Try the latest build."

            "network" in detail ||
                "timeout" in detail ||
                "timed out" in detail ||
                "unavailable" in detail ||
                "could not reach" in detail ->
                "Could not reach Aaris Remote. Check internet and try again."

            else ->
                error.message
                    ?.takeIf { it.length <= 120 }
                    ?: "Could not connect. Try again."
        }
    }

    private fun connectivityBlockMessage(): String? {
        val manager = getSystemService(ConnectivityManager::class.java)
        val network = manager.activeNetwork
            ?: return "No internet connection. Turn on Wi-Fi or mobile data and try again."
        val capabilities = manager.getNetworkCapabilities(network)
            ?: return "No internet connection. Turn on Wi-Fi or mobile data and try again."

        if (
            capabilities.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL
            )
        ) {
            return "Wi-Fi needs sign-in. Finish Wi-Fi sign-in and try again."
        }

        if (
            !capabilities.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_INTERNET
            )
        ) {
            return "No internet connection. Turn on Wi-Fi or mobile data and try again."
        }

        // Do not require NET_CAPABILITY_VALIDATED here. Android validation can
        // lag behind a usable route; Firebase's bounded timeout remains the
        // authority for uncertain-but-potentially-working networks.
        return null
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val CLIENT_DEADLINE_GRACE_MS = 2_000L
        private const val KEY_ACTIVE_HOST_SESSION =
            "active_host_session"
        private const val KEY_PENDING_PROJECTION_SESSION =
            "pending_projection_session"
        private const val KEY_PENDING_HOST_START_SESSION =
            "pending_host_start_session"
        private const val KEY_PENDING_SHARE_AFTER_ACCESSIBILITY =
            "pending_share_after_accessibility"
        private const val KEY_PENDING_SHARE_REQUESTED_AT =
            "pending_share_requested_at"
        private const val KEY_ACTIVE_HOST_CODE =
            "active_host_code"
        private const val KEY_ACTIVE_HOST_EXPIRES_AT =
            "active_host_expires_at"
        private const val KEY_NOTIFICATION_PERMISSION_ASKED =
            "notification_permission_asked"
        private const val ACCESSIBILITY_SERVICE_READY_TIMEOUT_MS =
            12_000L
        private const val ACCESSIBILITY_SERVICE_READY_POLL_MS =
            100L
        private const val PENDING_SHARE_MAX_AGE_MS =
            10 * 60_000L
    }
}
