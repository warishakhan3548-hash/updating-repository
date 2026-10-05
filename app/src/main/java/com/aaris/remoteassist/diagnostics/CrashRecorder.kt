package com.aaris.remoteassist.diagnostics

import android.content.Context
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.os.Build
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Reports uncaught JVM failures and OS-recorded process exits on the next
 * launch. Native crashes and memory kills do not invoke the JVM handler.
 */
object CrashRecorder {
    private const val PREFS = "aaris_crash_recorder"
    private const val KEY_CRASH = "last_crash"
    private const val KEY_EXIT_SEEN = "last_exit_seen_ms"
    private const val MAX_CHARS = 4_000

    fun install(context: Context) {
        val appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()

        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                val writer = StringWriter()
                error.printStackTrace(PrintWriter(writer))
                val stack = writer.toString()
                    .replace(appContext.packageName, "app")
                    .take(MAX_CHARS)
                appContext
                    .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putString(
                        KEY_CRASH,
                        error.javaClass.simpleName +
                            ": " +
                            (error.message ?: "no message") +
                            "\n" +
                            stack
                    )
                    .commit()
            }

            if (previous != null) {
                previous.uncaughtException(thread, error)
            }
        }
    }

    fun consume(context: Context): String? {
        val prefs = context.getSharedPreferences(
            PREFS,
            Context.MODE_PRIVATE
        )
        val crash = prefs.getString(KEY_CRASH, null)
        if (crash != null) {
            prefs.edit().remove(KEY_CRASH).apply()
        }
        val systemExit = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { consumeSystemExit(context) }.getOrNull()
        } else null
        return listOfNotNull(crash, systemExit).takeIf { it.isNotEmpty() }?.joinToString("\n\n")
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.R)
    private fun consumeSystemExit(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val exit = context.getSystemService(ActivityManager::class.java)
            .getHistoricalProcessExitReasons(context.packageName, 0, 8)
            .filter { it.processName == context.packageName }
            .maxByOrNull { it.timestamp } ?: return null
        if (exit.timestamp <= prefs.getLong(KEY_EXIT_SEEN, 0L)) return null
        prefs.edit().putLong(KEY_EXIT_SEEN, exit.timestamp).apply()
        if (System.currentTimeMillis() - exit.timestamp > 24 * 60 * 60 * 1_000L) return null
        val reason = when (exit.reason) {
            ApplicationExitInfo.REASON_LOW_MEMORY -> "Android reported low memory"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "Native process crash"
            ApplicationExitInfo.REASON_CRASH -> "Java/Kotlin process crash"
            ApplicationExitInfo.REASON_ANR -> "App stopped responding (ANR)"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "Android reported excessive resource usage"
            ApplicationExitInfo.REASON_SIGNALED -> "Process terminated by signal; memory pressure is unconfirmed"
            else -> return null
        }
        return "System exit: $reason\nStatus: ${exit.status}; PSS: ${exit.pss} KB; RSS: ${exit.rss} KB"
    }
}
