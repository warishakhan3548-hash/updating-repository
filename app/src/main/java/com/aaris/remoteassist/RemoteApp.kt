package com.aaris.remoteassist

import android.app.Application
import com.aaris.remoteassist.diagnostics.CrashRecorder
import com.aaris.remoteassist.session.SessionCoordinator

class RemoteApp : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashRecorder.install(this)
        SessionCoordinator.reset()
    }
}
