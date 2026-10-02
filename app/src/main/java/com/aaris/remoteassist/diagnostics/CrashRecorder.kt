package com.aaris.remoteassist.diagnostics

import android.content.Context
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Persists the last uncaught Java/Kotlin crash so a physical-device failure
 * can explain itself on the next launch instead of silently returning Home.
 */
object CrashRecorder {
    private const val PREFS = "aaris_crash_recorder"
    private const val KEY_CRASH = "last_crash"
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
        return crash
    }
}
