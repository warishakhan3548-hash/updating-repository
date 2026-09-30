package com.aaris.remoteassist.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import com.aaris.remoteassist.pairing.RemoteSessionView

class RemoteControlActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
            ?: return finish()
        val hostUid = intent.getStringExtra(EXTRA_HOST_UID)
            ?: return finish()

        setContentView(FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            addView(TextView(context).apply {
                text = "Connecting securely…\n${sessionId.take(8)}"
                setTextColor(0xFFFFFFFF.toInt())
                textSize = 18f
                gravity = Gravity.CENTER
            }, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
        })

        title = "Remote ${hostUid.take(6)}"
    }

    companion object {
        private const val EXTRA_SESSION_ID = "sessionId"
        private const val EXTRA_HOST_UID = "hostUid"

        fun intentFor(context: Context, session: RemoteSessionView): Intent =
            Intent(context, RemoteControlActivity::class.java)
                .putExtra(EXTRA_SESSION_ID, session.sessionId)
                .putExtra(EXTRA_HOST_UID, session.hostUid)
    }
}
