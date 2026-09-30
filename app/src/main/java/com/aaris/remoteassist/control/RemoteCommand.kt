package com.aaris.remoteassist.control

sealed interface RemoteCommand {
    val sessionId: String
    val leaseSecret: Long
    val generation: Int
    val sequence: Long
}

data class TapCommand(
    override val sessionId: String,
    override val leaseSecret: Long,
    override val generation: Int,
    override val sequence: Long,
    val xPx: Float,
    val yPx: Float
) : RemoteCommand

data class LongPressCommand(
    override val sessionId: String,
    override val leaseSecret: Long,
    override val generation: Int,
    override val sequence: Long,
    val xPx: Float,
    val yPx: Float,
    val durationMs: Long = 650L
) : RemoteCommand

data class SwipeCommand(
    override val sessionId: String,
    override val leaseSecret: Long,
    override val generation: Int,
    override val sequence: Long,
    val fromXPx: Float,
    val fromYPx: Float,
    val toXPx: Float,
    val toYPx: Float,
    val durationMs: Long
) : RemoteCommand

enum class GlobalAction { BACK, HOME, RECENTS }

data class GlobalActionCommand(
    override val sessionId: String,
    override val leaseSecret: Long,
    override val generation: Int,
    override val sequence: Long,
    val action: GlobalAction
) : RemoteCommand

data class SetTextCommand(
    override val sessionId: String,
    override val leaseSecret: Long,
    override val generation: Int,
    override val sequence: Long,
    val text: String
) : RemoteCommand
