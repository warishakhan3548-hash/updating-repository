package com.aaris.remoteassist.webrtc

data class SignalDescription(
    val type: String,
    val sdp: String
)

data class SignalCandidate(
    val sdpMid: String?,
    val sdpMLineIndex: Int,
    val sdp: String
)
