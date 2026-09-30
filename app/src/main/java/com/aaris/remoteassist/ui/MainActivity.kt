package com.aaris.remoteassist.ui

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
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import com.aaris.remoteassist.accessibility.PermissionGate
import com.aaris.remoteassist.capture.ScreenShareService
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.pairing.PairingCode
import com.aaris.remoteassist.pairing.PairingLink
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

class MainActivity : ComponentActivity() {
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
    private var hostStartInFlight = false

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())
        installBackHandler()

        val restoredHostSession = recoverPersistedHostSession()
        if (
            !restoredHostSession &&
            PermissionGate.isAccessibilityEnabled(this)
        ) {
            SessionCoordinator.prepareReady()
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
                    scheduleShareExpiry(ticket)
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
            hint = "000 000"
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

    private fun pairingCodeFromClipboard(): String? {
        val clipboard = getSystemService(ClipboardManager::class.java)
        if (!clipboard.hasPrimaryClip()) return null

        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null

        val raw = clip.getItemAt(0)
            .coerceToText(this)
            ?.toString()
            ?: return null

        return PairingCode.normalize(raw)
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
                                    scheduleShareExpiry(ticket)
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
                                        continueApprovedHostStart(sessionId)
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

        if (localSessionIsActive) return false

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
            textSize = 34f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
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

    private fun continueHostStart(sessionId: String) {
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

        approveAndRequestScreen(sessionId)
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
                    runCatching {
                        val current = SessionCoordinator.snapshot()
                        if (current.state == SessionState.PAIR_PENDING) {
                            SessionCoordinator.transition(
                                sessionId,
                                SessionState.HOST_APPROVED
                            )
                        } else {
                            require(
                                current.sessionId == sessionId &&
                                    current.state == SessionState.HOST_APPROVED
                            )
                        }
                    }.onFailure {
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
                    requestScreenPermission(sessionId)
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
        screenCaptureLauncher.launch(
            projectionManager.createScreenCaptureIntent()
        )
    }

    private fun scheduleShareExpiry(ticket: ShareTicket) {
        shareExpiryJob?.cancel()
        shareExpiryJob = scope.launch {
            val remaining =
                (ticket.expiresAtEpochMs - System.currentTimeMillis())
                    .coerceAtLeast(0L)
            delay(remaining)

            val state = SessionCoordinator.snapshot().state
            if (
                activeHostSessionId == ticket.sessionId &&
                (
                    state == SessionState.CODE_ACTIVE ||
                        state == SessionState.PAIR_PENDING
                )
            ) {
                endHostSession(
                    ticket.sessionId,
                    "Request expired. Tap Share to create a new code."
                )
            }
        }
    }

    private fun sendCode(code: String) {
        val plain = code.filter(Char::isDigit)
        val joinLink = PairingLink.uri(plain)
        val message =
            "Aaris Remote code: $plain\n" +
                "Tap to join: $joinLink\n" +
                "Or open Aaris Remote → Connect → START."

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
        hostStartInFlight = false
        clearHostUi()
        SessionCoordinator.close(sessionId)
        status.text = message
        setButtonsEnabled(true)

        scope.launch {
            runCatching { gateway.close(sessionId) }
        }
    }

    private fun clearHostUi() {
        activeHostSessionId = null
        pendingProjectionSessionId = null
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

        shareExpiryJob?.cancel()
        shareExpiryJob = null

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

        scope.launch {
            runCatching { gateway.close(sessionId) }
            SessionCoordinator.close(sessionId)
            clearHostUi()
            finish()
        }
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
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(20), dp(32), dp(20), dp(20))
        }

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        connectButton = Button(this).apply {
            text = "Connect"
            isAllCaps = false
            textSize = 18f
            setOnClickListener { showConnectDialog() }
        }

        shareButton = Button(this).apply {
            text = "Share"
            isAllCaps = false
            textSize = 18f
            setOnClickListener { requestShare() }
        }

        actions.addView(
            connectButton,
            LinearLayout.LayoutParams(
                0,
                dp(64),
                1f
            ).apply {
                marginEnd = dp(6)
            }
        )

        actions.addView(
            shareButton,
            LinearLayout.LayoutParams(
                0,
                dp(64),
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
            text = "Ready"
            gravity = Gravity.CENTER
            textSize = 14f
            setPadding(0, dp(20), 0, 0)
        }

        root.addView(
            status,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )
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
        private const val KEY_ACTIVE_HOST_SESSION =
            "active_host_session"
        private const val KEY_PENDING_PROJECTION_SESSION =
            "pending_projection_session"
        private const val KEY_PENDING_HOST_START_SESSION =
            "pending_host_start_session"
        private const val KEY_ACTIVE_HOST_CODE =
            "active_host_code"
        private const val KEY_ACTIVE_HOST_EXPIRES_AT =
            "active_host_expires_at"
    }
}
