package com.aaris.shield

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.aaris.shield.core.ShieldComponentId
import com.aaris.shield.core.ShieldComponentSnapshot
import com.aaris.shield.core.ShieldComponentState
import com.aaris.shield.core.ShieldRuntimeRegistry
import com.aaris.shield.network.NetworkShieldController

class MainActivity : Activity() {
    private lateinit var networkStatus: TextView
    private lateinit var networkButton: Button

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
                text = foundation.detail
                textSize = 16f
                gravity = Gravity.CENTER
            })
            networkStatus = TextView(context).apply {
                textSize = 16f
                gravity = Gravity.CENTER
                setPadding(0, 32, 0, 24)
            }
            addView(networkStatus)
            networkButton = Button(context).apply {
                setOnClickListener { toggleNetworkShield() }
            }
            addView(networkButton)
            addView(TextView(context).apply {
                text = "Step 2 filters ordinary DNS locally. Encrypted DNS inside other apps can bypass this layer."
                textSize = 13f
                gravity = Gravity.CENTER
                setPadding(0, 24, 0, 0)
            })
        }
        setContentView(content)
        renderNetworkStatus()
    }

    override fun onResume() {
        super.onResume()
        if (::networkStatus.isInitialized) renderNetworkStatus()
    }

    @Deprecated("VpnService.prepare uses the platform activity-result contract on the min SDK")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_VPN) return
        if (resultCode == RESULT_OK) {
            NetworkShieldController.start(this)
        }
        renderNetworkStatus()
    }

    private fun toggleNetworkShield() {
        val status = NetworkShieldController.status(this)
        if (status.requestedEnabled) {
            NetworkShieldController.stop(this)
            renderNetworkStatus()
            return
        }

        val permissionIntent = NetworkShieldController.prepareIntent(this)
        if (permissionIntent == null) {
            NetworkShieldController.start(this)
            renderNetworkStatus()
        } else {
            @Suppress("DEPRECATION")
            startActivityForResult(permissionIntent, REQUEST_VPN)
        }
    }

    private fun renderNetworkStatus() {
        val status = NetworkShieldController.status(this)
        networkStatus.text = status.detail
        networkButton.text = if (status.requestedEnabled) {
            "Disable Network Shield"
        } else {
            "Enable Network Shield"
        }
    }

    private companion object {
        const val REQUEST_VPN = 2202
    }
}
