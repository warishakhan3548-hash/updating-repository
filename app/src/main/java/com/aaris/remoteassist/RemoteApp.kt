package com.aaris.remoteassist

import android.app.Application
import com.aaris.remoteassist.session.SessionCoordinator
import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.appcheck.debug.DebugAppCheckProviderFactory
import com.google.firebase.appcheck.playintegrity.PlayIntegrityAppCheckProviderFactory

class RemoteApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SessionCoordinator.reset()

        if (FirebaseApp.getApps(this).isEmpty()) {
            FirebaseApp.initializeApp(this)
        }

        if (FirebaseApp.getApps(this).isNotEmpty()) {
            val providerFactory =
                if (BuildConfig.DEBUG) {
                    DebugAppCheckProviderFactory.getInstance()
                } else {
                    PlayIntegrityAppCheckProviderFactory.getInstance()
                }

            FirebaseAppCheck.getInstance()
                .installAppCheckProviderFactory(
                    providerFactory
                )
        }
    }
}
