package com.aaris.remoteassist.control

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class ControlPathPoint(
    val nx: Float,
    val ny: Float
)

sealed interface ControlPacket {
    data class Hello(
        val leaseSecret: Long,
        val generation: Int,
        val widthPx: Int,
        val heightPx: Int
    ) : ControlPacket

    data class Heartbeat(
        val leaseSecret: Long
    ) : ControlPacket

    data class Tap(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long,
        val nx: Float,
        val ny: Float
    ) : ControlPacket

    data class LongPress(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long,
        val nx: Float,
        val ny: Float,
        val durationMs: Int
    ) : ControlPacket

    data class Swipe(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long,
        val fromNx: Float,
        val fromNy: Float,
        val toNx: Float,
        val toNy: Float,
        val durationMs: Int
    ) : ControlPacket

    data class GesturePath(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long,
        val points: List<ControlPathPoint>,
        val durationMs: Int
    ) : ControlPacket

    data class GestureStream(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long,
        val streamId: Long,
        val phase: GestureStreamPhase,
        val points: List<ControlPathPoint>,
        val durationMs: Int
    ) : ControlPacket

    data class TwoFinger(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long,
        val firstFromNx: Float,
        val firstFromNy: Float,
        val firstToNx: Float,
        val firstToNy: Float,
        val secondFromNx: Float,
        val secondFromNy: Float,
        val secondToNx: Float,
        val secondToNy: Float,
        val durationMs: Int
    ) : ControlPacket

    data class Back(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long
    ) : ControlPacket

    data class Home(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long
    ) : ControlPacket

    data class Recents(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long
    ) : ControlPacket

    data class Text(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long,
        val text: String
    ) : ControlPacket

    data class CommandResult(
        val sequence: Long,
        val applied: Boolean
    ) : ControlPacket

    data class VideoRecoveryRequest(
        val leaseSecret: Long
    ) : ControlPacket

    data class PrimaryVideoReady(
        val leaseSecret: Long
    ) : ControlPacket

    data class InteractionState(
        val leaseSecret: Long,
        val active: Boolean
    ) : ControlPacket

    data object Disconnect : ControlPacket
}

object ControlProtocol {
    private const val VERSION: Byte = 1

    private const val HELLO: Byte = 1
    private const val HEARTBEAT: Byte = 2
    private const val TAP: Byte = 3
    private const val LONG_PRESS: Byte = 4
    private const val SWIPE: Byte = 5
    private const val BACK: Byte = 6
    private const val HOME: Byte = 7
    private const val DISCONNECT: Byte = 8
    private const val RECENTS: Byte = 9
    private const val TEXT: Byte = 10
    private const val TWO_FINGER: Byte = 11
    private const val GESTURE_PATH: Byte = 12
    private const val COMMAND_RESULT: Byte = 13
    private const val VIDEO_RECOVERY_REQUEST: Byte = 14
    private const val PRIMARY_VIDEO_READY: Byte = 15
    private const val INTERACTION_STATE: Byte = 16
    private const val GESTURE_STREAM: Byte = 17

    private const val MAX_TEXT_BYTES = 2048
    private const val MAX_GESTURE_PATH_POINTS = 96
    private const val MAX_GESTURE_STREAM_POINTS = 16

    fun encode(packet: ControlPacket): ByteArray {
        val textBytes = (packet as? ControlPacket.Text)
            ?.text
            ?.toByteArray(Charsets.UTF_8)
        if (textBytes != null) {
            require(textBytes.size <= MAX_TEXT_BYTES) {
                "Remote text is too large"
            }
        }

        if (packet is ControlPacket.GesturePath) {
            require(
                packet.points.size in 2..MAX_GESTURE_PATH_POINTS &&
                    packet.points.all {
                        it.nx.isFinite() && it.ny.isFinite()
                    }
            ) {
                "Remote gesture path is invalid"
            }
        }

        if (packet is ControlPacket.GestureStream) {
            require(
                packet.points.size in 1..MAX_GESTURE_STREAM_POINTS &&
                    packet.points.all {
                        it.nx.isFinite() && it.ny.isFinite()
                    }
            ) {
                "Remote gesture stream segment is invalid"
            }
        }

        val size = when (packet) {
            is ControlPacket.Hello -> 2 + 8 + 4 + 4 + 4
            is ControlPacket.Heartbeat -> 2 + 8
            is ControlPacket.Tap -> 2 + 8 + 4 + 8 + 2 + 2
            is ControlPacket.LongPress -> 2 + 8 + 4 + 8 + 2 + 2 + 2
            is ControlPacket.Swipe -> 2 + 8 + 4 + 8 + 2 + 2 + 2 + 2 + 2
            is ControlPacket.GesturePath ->
                2 + 8 + 4 + 8 + 1 + (packet.points.size * 4) + 2
            is ControlPacket.GestureStream ->
                2 + 8 + 4 + 8 + 8 + 1 + 1 +
                    (packet.points.size * 4) + 2
            is ControlPacket.TwoFinger ->
                2 + 8 + 4 + 8 + 2 + 2 + 2 + 2 + 2 + 2 + 2 + 2 + 2
            is ControlPacket.Back,
            is ControlPacket.Home,
            is ControlPacket.Recents -> 2 + 8 + 4 + 8
            is ControlPacket.Text -> 2 + 8 + 4 + 8 + 2 + checkNotNull(textBytes).size
            is ControlPacket.CommandResult -> 2 + 8 + 1
            is ControlPacket.VideoRecoveryRequest,
            is ControlPacket.PrimaryVideoReady -> 2 + 8
            is ControlPacket.InteractionState -> 2 + 8 + 1
            ControlPacket.Disconnect -> 2
        }

        val buffer = ByteBuffer.allocate(size)
            .order(ByteOrder.BIG_ENDIAN)

        buffer.put(VERSION)
        buffer.put(typeOf(packet))

        when (packet) {
            is ControlPacket.Hello -> {
                buffer.putLong(packet.leaseSecret)
                buffer.putInt(packet.generation)
                buffer.putInt(packet.widthPx)
                buffer.putInt(packet.heightPx)
            }

            is ControlPacket.Heartbeat -> {
                buffer.putLong(packet.leaseSecret)
            }

            is ControlPacket.Tap -> {
                putCommandHeader(
                    buffer,
                    packet.leaseSecret,
                    packet.generation,
                    packet.sequence
                )
                putUnit(buffer, packet.nx)
                putUnit(buffer, packet.ny)
            }

            is ControlPacket.LongPress -> {
                putCommandHeader(
                    buffer,
                    packet.leaseSecret,
                    packet.generation,
                    packet.sequence
                )
                putUnit(buffer, packet.nx)
                putUnit(buffer, packet.ny)
                buffer.putShort(
                    packet.durationMs.coerceIn(250, 5_000).toShort()
                )
            }

            is ControlPacket.Swipe -> {
                putCommandHeader(
                    buffer,
                    packet.leaseSecret,
                    packet.generation,
                    packet.sequence
                )
                putUnit(buffer, packet.fromNx)
                putUnit(buffer, packet.fromNy)
                putUnit(buffer, packet.toNx)
                putUnit(buffer, packet.toNy)
                buffer.putShort(
                    packet.durationMs.coerceIn(80, 5_000).toShort()
                )
            }

            is ControlPacket.GesturePath -> {
                putCommandHeader(
                    buffer,
                    packet.leaseSecret,
                    packet.generation,
                    packet.sequence
                )
                buffer.put(packet.points.size.toByte())
                packet.points.forEach { point ->
                    putUnit(buffer, point.nx)
                    putUnit(buffer, point.ny)
                }
                buffer.putShort(
                    packet.durationMs.coerceIn(80, 5_000).toShort()
                )
            }

            is ControlPacket.GestureStream -> {
                putCommandHeader(
                    buffer,
                    packet.leaseSecret,
                    packet.generation,
                    packet.sequence
                )
                buffer.putLong(packet.streamId)
                buffer.put(packet.phase.ordinal.toByte())
                buffer.put(packet.points.size.toByte())
                packet.points.forEach { point ->
                    putUnit(buffer, point.nx)
                    putUnit(buffer, point.ny)
                }
                buffer.putShort(
                    packet.durationMs.coerceIn(12, 1_000).toShort()
                )
            }

            is ControlPacket.TwoFinger -> {
                putCommandHeader(
                    buffer,
                    packet.leaseSecret,
                    packet.generation,
                    packet.sequence
                )
                putUnit(buffer, packet.firstFromNx)
                putUnit(buffer, packet.firstFromNy)
                putUnit(buffer, packet.firstToNx)
                putUnit(buffer, packet.firstToNy)
                putUnit(buffer, packet.secondFromNx)
                putUnit(buffer, packet.secondFromNy)
                putUnit(buffer, packet.secondToNx)
                putUnit(buffer, packet.secondToNy)
                buffer.putShort(
                    packet.durationMs.coerceIn(80, 5_000).toShort()
                )
            }

            is ControlPacket.Back -> putCommandHeader(
                buffer,
                packet.leaseSecret,
                packet.generation,
                packet.sequence
            )

            is ControlPacket.Home -> putCommandHeader(
                buffer,
                packet.leaseSecret,
                packet.generation,
                packet.sequence
            )

            is ControlPacket.Recents -> putCommandHeader(
                buffer,
                packet.leaseSecret,
                packet.generation,
                packet.sequence
            )

            is ControlPacket.Text -> {
                putCommandHeader(
                    buffer,
                    packet.leaseSecret,
                    packet.generation,
                    packet.sequence
                )
                val bytes = checkNotNull(textBytes)
                buffer.putShort(bytes.size.toShort())
                buffer.put(bytes)
            }

            is ControlPacket.CommandResult -> {
                buffer.putLong(packet.sequence)
                buffer.put((if (packet.applied) 1 else 0).toByte())
            }

            is ControlPacket.VideoRecoveryRequest -> {
                buffer.putLong(packet.leaseSecret)
            }

            is ControlPacket.PrimaryVideoReady -> {
                buffer.putLong(packet.leaseSecret)
            }

            is ControlPacket.InteractionState -> {
                buffer.putLong(packet.leaseSecret)
                buffer.put((if (packet.active) 1 else 0).toByte())
            }

            ControlPacket.Disconnect -> Unit
        }

        return buffer.array()
    }

    fun decode(bytes: ByteArray): ControlPacket? {
        if (bytes.size < 2) return null
        val buffer = ByteBuffer.wrap(bytes)
            .order(ByteOrder.BIG_ENDIAN)

        if (buffer.get() != VERSION) return null
        val type = buffer.get()

        return runCatching {
            when (type) {
                HELLO -> {
                    require(buffer.remaining() == 20)
                    ControlPacket.Hello(
                        leaseSecret = buffer.long,
                        generation = buffer.int,
                        widthPx = buffer.int,
                        heightPx = buffer.int
                    )
                }

                HEARTBEAT -> {
                    require(buffer.remaining() == 8)
                    ControlPacket.Heartbeat(buffer.long)
                }

                TAP -> {
                    require(buffer.remaining() == 24)
                    val header = readHeader(buffer)
                    ControlPacket.Tap(
                        header.leaseSecret,
                        header.generation,
                        header.sequence,
                        getUnit(buffer),
                        getUnit(buffer)
                    )
                }

                LONG_PRESS -> {
                    require(buffer.remaining() == 26)
                    val header = readHeader(buffer)
                    ControlPacket.LongPress(
                        header.leaseSecret,
                        header.generation,
                        header.sequence,
                        getUnit(buffer),
                        getUnit(buffer),
                        buffer.short.toInt() and 0xffff
                    )
                }

                SWIPE -> {
                    require(buffer.remaining() == 30)
                    val header = readHeader(buffer)
                    ControlPacket.Swipe(
                        header.leaseSecret,
                        header.generation,
                        header.sequence,
                        getUnit(buffer),
                        getUnit(buffer),
                        getUnit(buffer),
                        getUnit(buffer),
                        buffer.short.toInt() and 0xffff
                    )
                }

                GESTURE_PATH -> {
                    require(buffer.remaining() >= 31)
                    val header = readHeader(buffer)
                    val count = buffer.get().toInt() and 0xff
                    require(count in 2..MAX_GESTURE_PATH_POINTS)
                    require(buffer.remaining() == count * 4 + 2)
                    val points = List(count) {
                        ControlPathPoint(
                            nx = getUnit(buffer),
                            ny = getUnit(buffer)
                        )
                    }
                    ControlPacket.GesturePath(
                        header.leaseSecret,
                        header.generation,
                        header.sequence,
                        points,
                        buffer.short.toInt() and 0xffff
                    )
                }

                GESTURE_STREAM -> {
                    require(buffer.remaining() >= 36)
                    val header = readHeader(buffer)
                    val streamId = buffer.long
                    val phaseIndex = buffer.get().toInt() and 0xff
                    val phase =
                        GestureStreamPhase.values()
                            .getOrNull(phaseIndex)
                            ?: error("Invalid gesture stream phase")
                    val count = buffer.get().toInt() and 0xff
                    require(count in 1..MAX_GESTURE_STREAM_POINTS)
                    require(buffer.remaining() == count * 4 + 2)
                    val points = List(count) {
                        ControlPathPoint(
                            nx = getUnit(buffer),
                            ny = getUnit(buffer)
                        )
                    }
                    ControlPacket.GestureStream(
                        leaseSecret = header.leaseSecret,
                        generation = header.generation,
                        sequence = header.sequence,
                        streamId = streamId,
                        phase = phase,
                        points = points,
                        durationMs = buffer.short.toInt() and 0xffff
                    )
                }

                TWO_FINGER -> {
                    require(buffer.remaining() == 38)
                    val header = readHeader(buffer)
                    ControlPacket.TwoFinger(
                        header.leaseSecret,
                        header.generation,
                        header.sequence,
                        getUnit(buffer),
                        getUnit(buffer),
                        getUnit(buffer),
                        getUnit(buffer),
                        getUnit(buffer),
                        getUnit(buffer),
                        getUnit(buffer),
                        getUnit(buffer),
                        buffer.short.toInt() and 0xffff
                    )
                }

                BACK -> {
                    require(buffer.remaining() == 20)
                    val header = readHeader(buffer)
                    ControlPacket.Back(
                        header.leaseSecret,
                        header.generation,
                        header.sequence
                    )
                }

                HOME -> {
                    require(buffer.remaining() == 20)
                    val header = readHeader(buffer)
                    ControlPacket.Home(
                        header.leaseSecret,
                        header.generation,
                        header.sequence
                    )
                }

                RECENTS -> {
                    require(buffer.remaining() == 20)
                    val header = readHeader(buffer)
                    ControlPacket.Recents(
                        header.leaseSecret,
                        header.generation,
                        header.sequence
                    )
                }

                TEXT -> {
                    require(buffer.remaining() >= 22)
                    val header = readHeader(buffer)
                    val length = buffer.short.toInt() and 0xffff
                    require(length <= MAX_TEXT_BYTES)
                    require(buffer.remaining() == length)
                    val payload = ByteArray(length)
                    buffer.get(payload)
                    ControlPacket.Text(
                        header.leaseSecret,
                        header.generation,
                        header.sequence,
                        payload.toString(Charsets.UTF_8)
                    )
                }

                COMMAND_RESULT -> {
                    require(buffer.remaining() == 9)
                    val sequence = buffer.long
                    val applied = when (val value = buffer.get().toInt()) {
                        0 -> false
                        1 -> true
                        else -> error("Invalid command result")
                    }
                    ControlPacket.CommandResult(sequence, applied)
                }

                VIDEO_RECOVERY_REQUEST -> {
                    require(buffer.remaining() == 8)
                    ControlPacket.VideoRecoveryRequest(
                        leaseSecret = buffer.long
                    )
                }

                PRIMARY_VIDEO_READY -> {
                    require(buffer.remaining() == 8)
                    ControlPacket.PrimaryVideoReady(
                        leaseSecret = buffer.long
                    )
                }

                INTERACTION_STATE -> {
                    require(buffer.remaining() == 9)
                    val leaseSecret = buffer.long
                    val active = when (buffer.get().toInt()) {
                        0 -> false
                        1 -> true
                        else -> error("Invalid interaction state")
                    }
                    ControlPacket.InteractionState(
                        leaseSecret = leaseSecret,
                        active = active
                    )
                }

                DISCONNECT -> {
                    require(buffer.remaining() == 0)
                    ControlPacket.Disconnect
                }

                else -> null
            }
        }.getOrNull()
    }

    fun toRemoteCommand(
        sessionId: String,
        packet: ControlPacket,
        widthPx: Int,
        heightPx: Int
    ): RemoteCommand? {
        if (widthPx <= 0 || heightPx <= 0) return null

        fun x(nx: Float): Float =
            nx.coerceIn(0f, 1f) * (widthPx - 1).coerceAtLeast(1)

        fun y(ny: Float): Float =
            ny.coerceIn(0f, 1f) * (heightPx - 1).coerceAtLeast(1)

        return when (packet) {
            is ControlPacket.Tap -> TapCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                xPx = x(packet.nx),
                yPx = y(packet.ny)
            )

            is ControlPacket.LongPress -> LongPressCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                xPx = x(packet.nx),
                yPx = y(packet.ny),
                durationMs = packet.durationMs.toLong()
            )

            is ControlPacket.Swipe -> SwipeCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                fromXPx = x(packet.fromNx),
                fromYPx = y(packet.fromNy),
                toXPx = x(packet.toNx),
                toYPx = y(packet.toNy),
                durationMs = packet.durationMs.toLong()
            )

            is ControlPacket.GesturePath -> GesturePathCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                points = packet.points.map { point ->
                    RemotePathPoint(
                        xPx = x(point.nx),
                        yPx = y(point.ny)
                    )
                },
                durationMs = packet.durationMs.toLong()
            )

            is ControlPacket.GestureStream -> GestureStreamCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                streamId = packet.streamId,
                phase = packet.phase,
                points = packet.points.map { point ->
                    RemotePathPoint(
                        xPx = x(point.nx),
                        yPx = y(point.ny)
                    )
                },
                durationMs = packet.durationMs.toLong()
            )

            is ControlPacket.TwoFinger -> TwoFingerCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                firstFromXPx = x(packet.firstFromNx),
                firstFromYPx = y(packet.firstFromNy),
                firstToXPx = x(packet.firstToNx),
                firstToYPx = y(packet.firstToNy),
                secondFromXPx = x(packet.secondFromNx),
                secondFromYPx = y(packet.secondFromNy),
                secondToXPx = x(packet.secondToNx),
                secondToYPx = y(packet.secondToNy),
                durationMs = packet.durationMs.toLong()
            )

            is ControlPacket.Back -> GlobalActionCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                action = GlobalAction.BACK
            )

            is ControlPacket.Home -> GlobalActionCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                action = GlobalAction.HOME
            )

            is ControlPacket.Recents -> GlobalActionCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                action = GlobalAction.RECENTS
            )

            is ControlPacket.Text -> SetTextCommand(
                sessionId = sessionId,
                leaseSecret = packet.leaseSecret,
                generation = packet.generation,
                sequence = packet.sequence,
                text = packet.text
            )

            is ControlPacket.Hello,
            is ControlPacket.Heartbeat,
            is ControlPacket.CommandResult,
            is ControlPacket.VideoRecoveryRequest,
            is ControlPacket.PrimaryVideoReady,
            is ControlPacket.InteractionState,
            ControlPacket.Disconnect -> null
        }
    }

    private data class Header(
        val leaseSecret: Long,
        val generation: Int,
        val sequence: Long
    )

    private fun putCommandHeader(
        buffer: ByteBuffer,
        leaseSecret: Long,
        generation: Int,
        sequence: Long
    ) {
        buffer.putLong(leaseSecret)
        buffer.putInt(generation)
        buffer.putLong(sequence)
    }

    private fun readHeader(buffer: ByteBuffer): Header = Header(
        leaseSecret = buffer.long,
        generation = buffer.int,
        sequence = buffer.long
    )

    private fun putUnit(buffer: ByteBuffer, value: Float) {
        val quantized =
            (value.coerceIn(0f, 1f) * 65535f).toInt()
        buffer.putShort(quantized.toShort())
    }

    private fun getUnit(buffer: ByteBuffer): Float {
        val value = buffer.short.toInt() and 0xffff
        return value / 65535f
    }

    private fun typeOf(packet: ControlPacket): Byte = when (packet) {
        is ControlPacket.Hello -> HELLO
        is ControlPacket.Heartbeat -> HEARTBEAT
        is ControlPacket.Tap -> TAP
        is ControlPacket.LongPress -> LONG_PRESS
        is ControlPacket.Swipe -> SWIPE
        is ControlPacket.GesturePath -> GESTURE_PATH
        is ControlPacket.GestureStream -> GESTURE_STREAM
        is ControlPacket.TwoFinger -> TWO_FINGER
        is ControlPacket.Back -> BACK
        is ControlPacket.Home -> HOME
        is ControlPacket.Recents -> RECENTS
        is ControlPacket.Text -> TEXT
        is ControlPacket.CommandResult -> COMMAND_RESULT
        is ControlPacket.VideoRecoveryRequest ->
            VIDEO_RECOVERY_REQUEST
        is ControlPacket.PrimaryVideoReady ->
            PRIMARY_VIDEO_READY
        is ControlPacket.InteractionState ->
            INTERACTION_STATE
        ControlPacket.Disconnect -> DISCONNECT
    }
}
