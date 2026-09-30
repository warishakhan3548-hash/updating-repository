package com.aaris.remoteassist.control

import java.nio.ByteBuffer
import java.nio.ByteOrder

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

    fun encode(packet: ControlPacket): ByteArray {
        val size = when (packet) {
            is ControlPacket.Hello -> 2 + 8 + 4 + 4 + 4
            is ControlPacket.Heartbeat -> 2 + 8
            is ControlPacket.Tap -> 2 + 8 + 4 + 8 + 2 + 2
            is ControlPacket.LongPress -> 2 + 8 + 4 + 8 + 2 + 2 + 2
            is ControlPacket.Swipe -> 2 + 8 + 4 + 8 + 2 + 2 + 2 + 2 + 2
            is ControlPacket.Back,
            is ControlPacket.Home,
            is ControlPacket.Recents -> 2 + 8 + 4 + 8
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

                DISCONNECT -> {
                    require(buffer.remaining() == 0)
                    ControlPacket.Disconnect
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

            is ControlPacket.Hello,
            is ControlPacket.Heartbeat,
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
        is ControlPacket.Back -> BACK
        is ControlPacket.Home -> HOME
        is ControlPacket.Recents -> RECENTS
        ControlPacket.Disconnect -> DISCONNECT
    }
}
