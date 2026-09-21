package com.aaris.shield

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.aaris.shield.core.ShieldComponentId
import com.aaris.shield.core.ShieldComponentSnapshot
import com.aaris.shield.core.ShieldComponentState
import com.aaris.shield.core.ShieldRuntimeRegistry
import com.aaris.shield.network.NetworkShieldStateStore
import com.aaris.shield.network.NetworkShieldStatus
import com.aaris.shield.network.NetworkShieldVpnService

class MainActivity : Activity() {
    private lateinit var statusView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val registry = ShieldRuntimeRegistry(
            listOf(
                ShieldComponentSnapshot(
                    id = ShieldComponentId.FOUNDATION,
                    state = ShieldComponentState.READY,
                    detail = "Architecture foundation active",
                ),
            ),
        )
        val foundation = requireNotNull(registry.get(ShieldComponentId.FOUNDATION))

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)

            addView(TextView(context).apply {
                text = getString(R.string.app_name)
                textSize = 28f
                gravity = Gravity.CENTER
            })
            addView(TextView(context).apply {
                text = "${foundation.detail}. Step 2 adds local DNS domain protection only."
                textSize = 16f
                gravity = Gravity.CENTER
            })

            statusView = TextView(context).apply {
                textSize = 16f
                gravity = Gravity.CENTER
                setPadding(0, 32, 0, 24)
            }
            addView(statusView)

            addView(Button(context).apply {
                text = "Enable Network Shield"
                setOnClickListener { requestVpnAndStart() }
            })
            addView(Button(context).apply {
                text = "Disable Network Shield"
                setOnClickListener {
                    NetworkShieldVpnService.stop(this@MainActivity)
                    refreshStatus()
                }
            })
        }
        setContentView(content)
        refreshStatus()
    }

    override fun onResume() {
        super.onResume()
        if (::statusView.isInitialized) refreshStatus()
    }

    @Deprecated("VpnService consent uses the platform activity result on the minSdk baseline")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                startNetworkShield()
            } else {
                NetworkShieldStateStore.setRequested(this, false)
                NetworkShieldStateStore.setStatus(
                    this,
                    NetworkShieldStatus.OFF,
                    "VPN permission was not granted",
                )
                refreshStatus()
            }
        }
    }

    private fun requestVpnAndStart() {
        val consentIntent = VpnService.prepare(this)
        if (consentIntent == null) {
            startNetworkShield()
        } else {
            @Suppress("DEPRECATION")
            startActivityForResult(consentIntent, VPN_REQUEST_CODE)
        }
    }

    private fun startNetworkShield() {
        runCatching { NetworkShieldVpnService.start(this) }
            .onFailure {
                NetworkShieldStateStore.setRequested(this, false)
                NetworkShieldStateStore.setStatus(
                    this,
                    NetworkShieldStatus.FAILED,
                    "Android could not start the VPN service",
                )
            }
        refreshStatus()
    }

    private fun refreshStatus() {
        val status = NetworkShieldStateStore.status(this)
        statusView.text = when (status) {
            NetworkShieldStatus.OFF -> "Network Shield: off"
            NetworkShieldStatus.STARTING -> "Network Shield: starting"
            NetworkShieldStatus.ACTIVE -> "Network Shield: active"
            NetworkShieldStatus.FAILED -> "Network Shield: ${NetworkShieldStateStore.detail(this)}"
        }
    }

    companion object {
        private const val VPN_REQUEST_CODE = 4202
    }
}
