package com.aaris.shield.network

import android.content.Context

enum class NetworkShieldState {
    STOPPED,
    STARTING,
    RUNNING,
    CONSENT_REQUIRED,
    DEGRADED,
}

data class NetworkShieldStatus(
    val state: NetworkShieldState,
    val detail: String,
    val requestedEnabled: Boolean,
)

internal object NetworkShieldStateStore {
    private const val PREFS = "aaris_shield_network"
    private const val KEY_REQUESTED = "requested_enabled"
    private const val KEY_STATE = "state"
    private const val KEY_DETAIL = "detail"

    fun setRequested(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_REQUESTED, enabled).apply()
    }

    fun isRequested(context: Context): Boolean = prefs(context).getBoolean(KEY_REQUESTED, false)

    fun update(context: Context, state: NetworkShieldState, detail: String) {
        prefs(context).edit()
            .putString(KEY_STATE, state.name)
            .putString(KEY_DETAIL, detail.take(240))
            .apply()
    }

    fun read(context: Context): NetworkShieldStatus {
        val preferences = prefs(context)
        val state = runCatching {
            NetworkShieldState.valueOf(preferences.getString(KEY_STATE, null) ?: NetworkShieldState.STOPPED.name)
        }.getOrDefault(NetworkShieldState.STOPPED)
        val detail = preferences.getString(KEY_DETAIL, null)
            ?: if (state == NetworkShieldState.STOPPED) "Network shield stopped" else state.name
        return NetworkShieldStatus(
            state = state,
            detail = detail,
            requestedEnabled = preferences.getBoolean(KEY_REQUESTED, false),
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
