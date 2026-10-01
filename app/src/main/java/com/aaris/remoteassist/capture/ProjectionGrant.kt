package com.aaris.remoteassist.capture

import android.content.Intent

data class ProjectionGrant(
    val sessionId: String,
    val resultCode: Int,
    val data: Intent
)
