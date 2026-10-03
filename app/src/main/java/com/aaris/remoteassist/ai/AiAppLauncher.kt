package com.aaris.remoteassist.ai

import android.content.Context
import android.content.Intent

object AiAppLauncher {
    @Suppress("DEPRECATION")
    fun launch(context: Context, query: String): Boolean {
        if (query.isBlank() || query.length > 160) return false
        val packageManager = context.packageManager
        val exactPackage = query.trim()
        packageManager.getLaunchIntentForPackage(exactPackage)?.let { launchIntent ->
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            return runCatching {
                context.startActivity(launchIntent)
                true
            }.getOrDefault(false)
        }
        val launcherQuery = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val candidates = packageManager.queryIntentActivities(launcherQuery, 0).mapNotNull { info ->
            val activity = info.activityInfo ?: return@mapNotNull null
            val label = runCatching { info.loadLabel(packageManager)?.toString() }.getOrNull().orEmpty()
            if (label.isBlank()) return@mapNotNull null
            AiLaunchCandidate(label, activity.packageName, activity.name)
        }
        val selected = AiAppMatcher.choose(query, candidates) ?: return false
        val launchIntent = packageManager.getLaunchIntentForPackage(selected.packageName)
            ?: Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setClassName(selected.packageName, selected.activityName)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return runCatching {
            context.startActivity(launchIntent)
            true
        }.getOrDefault(false)
    }
}
