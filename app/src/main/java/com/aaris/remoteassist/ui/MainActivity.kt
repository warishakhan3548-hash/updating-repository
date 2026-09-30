package com.aaris.remoteassist.ui

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
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
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.pairing.PairingCode
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
        scope.cancel()
        super.onDestroy()
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
                .onSuccess {
                    status.text = "Request sent. Waiting for your friend to approve."
                }
                .onFailure { showBackendError(it) }
        }
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
}
