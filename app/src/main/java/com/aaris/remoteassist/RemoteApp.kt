package com.aaris.remoteassist

import android.app.Application
import com.aaris.remoteassist.session.SessionCoordinator

class RemoteApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SessionCoordinator.reset()
    }
}
