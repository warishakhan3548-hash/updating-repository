package com.aaris.remoteassist.webrtc

data class SignalDescription(
    val type: String,
    val sdp: String,
    val negotiationId: String = LEGACY_NEGOTIATION_ID
)

data class SignalCandidate(
    val sdpMid: String?,
    val sdpMLineIndex: Int,
    val sdp: String,
    val negotiationId: String = LEGACY_NEGOTIATION_ID
)

const val LEGACY_NEGOTIATION_ID = "legacy"
