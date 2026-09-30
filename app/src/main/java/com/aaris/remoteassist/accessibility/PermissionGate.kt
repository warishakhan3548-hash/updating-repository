package com.aaris.remoteassist.accessibility

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.text.TextUtils

object PermissionGate {
    fun isAccessibilityEnabled(context: Context): Boolean {
        val expected = ComponentName(
            context,
            AssistAccessibilityService::class.java
        ).flattenToString()

        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        val splitter = TextUtils.SimpleStringSplitter(':')
        splitter.setString(enabled)
        while (splitter.hasNext()) {
            if (splitter.next().equals(expected, ignoreCase = true)) return true
        }
        return false
    }

    fun openAccessibilitySettings(context: Context) {
        val flags = Intent.FLAG_ACTIVITY_NEW_TASK
        val targeted = Intent(
            "android.settings.ACCESSIBILITY_DETAILS_SETTINGS",
            Uri.parse("package:${context.packageName}")
        ).addFlags(flags)

        val fallback = Intent(
            Settings.ACTION_ACCESSIBILITY_SETTINGS
        ).addFlags(flags)

        runCatching {
            context.startActivity(targeted)
        }.getOrElse {
            context.startActivity(fallback)
        }
    }
}
