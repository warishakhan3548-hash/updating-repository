package com.aaris.remoteassist

import android.app.Application
import com.aaris.remoteassist.session.SessionRuntime
import com.google.firebase.FirebaseApp

class RemoteApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SessionRuntime.reset()
        runCatching { FirebaseApp.initializeApp(this) }
    }
}
