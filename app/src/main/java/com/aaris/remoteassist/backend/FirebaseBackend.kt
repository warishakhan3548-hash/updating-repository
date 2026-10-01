package com.aaris.remoteassist.backend

import com.google.firebase.database.FirebaseDatabase

object FirebaseBackend {
    const val DATABASE_URL =
        "https://aaris-control-default-rtdb.asia-southeast1.firebasedatabase.app"

    fun database(): FirebaseDatabase =
        FirebaseDatabase.getInstance(DATABASE_URL)
}
