package com.aaris.shield.network

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build

object NetworkShieldController {
    fun prepareIntent(context: Context): Intent? = VpnService.prepare(context)

    fun start(context: Context) {
        NetworkShieldStateStore.setRequested(context, true)
        NetworkShieldStateStore.update(context, NetworkShieldState.STARTING, "Starting local DNS shield")
        val intent = Intent(context, NetworkShieldVpnService::class.java)
            .setAction(NetworkShieldVpnService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun stop(context: Context) {
        NetworkShieldStateStore.setRequested(context, false)
        context.stopService(Intent(context, NetworkShieldVpnService::class.java))
        NetworkShieldStateStore.update(context, NetworkShieldState.STOPPED, "Network shield stopped")
    }

    fun status(context: Context): NetworkShieldStatus = NetworkShieldStateStore.read(context)
}
