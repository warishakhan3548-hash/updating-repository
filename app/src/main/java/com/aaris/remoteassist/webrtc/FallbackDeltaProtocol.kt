package com.aaris.remoteassist.webrtc

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class FallbackDeltaPatch(
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
    val jpeg: ByteArray
)

data class FallbackDeltaFrame(
    val frameId: Long,
    val baseFrameId: Long,
    val width: Int,
    val height: Int,
    val rotation: Int,
    val shiftX: Int,
    val shiftY: Int,
    val patches: List<FallbackDeltaPatch>
)

/**
 * Atomic delta transport for compatibility video.
 *
 * A delta is applied only when the controller currently displays baseFrameId.
 * Every delta is assembled completely before it becomes visible, so a missing
 * SCTP chunk can never leave half of the remote screen updated. Periodic legacy
 * JPEG keyframes remain the recovery anchor and keep mixed-version sessions
 * functional.
 */
object FallbackDeltaProtocol {
    private const val MAGIC = 0x41524432 // "ARD2"
    private const val PAYLOAD_VERSION: Byte = 1
    private const val CHUNK_HEADER_BYTES = 20
    private const val MAX_CHUNK_PAYLOAD = 12_000
    private const val MAX_CHUNKS = 64
    private const val MAX_UPDATE_BYTES = 720_000
    private const val MAX_PATCHES = 24

    fun encode(frame: FallbackDeltaFrame): List<ByteArray> {
        validate(frame)

        val payloadBytes =
            1 + 8 + 2 + 2 + 2 + 2 + 2 + 1 +
                frame.patches.sumOf { patch ->
                    2 + 2 + 2 + 2 + 4 + patch.jpeg.size
                }
        require(payloadBytes in 1..MAX_UPDATE_BYTES)

        val payload =
            ByteBuffer.allocate(payloadBytes)
                .order(ByteOrder.BIG_ENDIAN)
                .apply {
                    put(PAYLOAD_VERSION)
                    putLong(frame.baseFrameId)
                    putShort(frame.width.toShort())
                    putShort(frame.height.toShort())
                    putShort(frame.rotation.toShort())
                    putShort(frame.shiftX.toShort())
                    putShort(frame.shiftY.toShort())
                    put(frame.patches.size.toByte())
                    frame.patches.forEach { patch ->
                        putShort(patch.x.toShort())
                        putShort(patch.y.toShort())
                        putShort(patch.width.toShort())
                        putShort(patch.height.toShort())
                        putInt(patch.jpeg.size)
                        put(patch.jpeg)
                    }
                }
                .array()

        val count =
            (payload.size + MAX_CHUNK_PAYLOAD - 1) /
                MAX_CHUNK_PAYLOAD
        require(count in 1..MAX_CHUNKS)

        return List(count) { index ->
            val start = index * MAX_CHUNK_PAYLOAD
            val length =
                minOf(
                    MAX_CHUNK_PAYLOAD,
                    payload.size - start
                )

            ByteBuffer
                .allocate(CHUNK_HEADER_BYTES + length)
                .order(ByteOrder.BIG_ENDIAN)
                .apply {
                    putInt(MAGIC)
                    putLong(frame.frameId)
                    putShort(index.toShort())
                    putShort(count.toShort())
                    putShort(length.toShort())
                    putShort(0)
                    put(payload, start, length)
                }
                .array()
        }
    }

    private data class Chunk(
        val frameId: Long,
        val index: Int,
        val count: Int,
        val payload: ByteArray
    )

    private fun decodeChunk(bytes: ByteArray): Chunk? {
        if (bytes.size < CHUNK_HEADER_BYTES) return null

        return runCatching {
            val buffer =
                ByteBuffer.wrap(bytes)
                    .order(ByteOrder.BIG_ENDIAN)
            if (buffer.int != MAGIC) return null

            val frameId = buffer.long
            val index = buffer.short.toInt() and 0xffff
            val count = buffer.short.toInt() and 0xffff
            val length = buffer.short.toInt() and 0xffff
            buffer.short // reserved

            require(frameId > 0L)
            require(count in 1..MAX_CHUNKS)
            require(index in 0 until count)
            require(length in 1..MAX_CHUNK_PAYLOAD)
            require(buffer.remaining() == length)

            val payload = ByteArray(length)
            buffer.get(payload)
            Chunk(frameId, index, count, payload)
        }.getOrNull()
    }

    private fun decodePayload(
        frameId: Long,
        bytes: ByteArray
    ): FallbackDeltaFrame? {
        if (bytes.isEmpty() || bytes.size > MAX_UPDATE_BYTES) return null

        return runCatching {
            val buffer =
                ByteBuffer.wrap(bytes)
                    .order(ByteOrder.BIG_ENDIAN)
            require(buffer.get() == PAYLOAD_VERSION)

            val baseFrameId = buffer.long
            val width = buffer.short.toInt() and 0xffff
            val height = buffer.short.toInt() and 0xffff
            val rotation = buffer.short.toInt() and 0xffff
            val shiftX = buffer.short.toInt()
            val shiftY = buffer.short.toInt()
            val patchCount = buffer.get().toInt() and 0xff

            require(baseFrameId >= 0L && baseFrameId < frameId)
            require(width in 2..4096)
            require(height in 2..4096)
            require(rotation in setOf(0, 90, 180, 270))
            require(shiftX in -4096..4096)
            require(shiftY in -4096..4096)
            require(patchCount in 1..MAX_PATCHES)

            val patches = ArrayList<FallbackDeltaPatch>(patchCount)
            repeat(patchCount) {
                require(buffer.remaining() >= 12)
                val x = buffer.short.toInt() and 0xffff
                val y = buffer.short.toInt() and 0xffff
                val patchWidth = buffer.short.toInt() and 0xffff
                val patchHeight = buffer.short.toInt() and 0xffff
                val length = buffer.int

                require(patchWidth > 0 && patchHeight > 0)
                require(x + patchWidth <= width)
                require(y + patchHeight <= height)
                require(length in 1..MAX_UPDATE_BYTES)
                require(buffer.remaining() >= length)

                val jpeg = ByteArray(length)
                buffer.get(jpeg)
                patches +=
                    FallbackDeltaPatch(
                        x = x,
                        y = y,
                        width = patchWidth,
                        height = patchHeight,
                        jpeg = jpeg
                    )
            }
            require(buffer.remaining() == 0)

            FallbackDeltaFrame(
                frameId = frameId,
                baseFrameId = baseFrameId,
                width = width,
                height = height,
                rotation = rotation,
                shiftX = shiftX,
                shiftY = shiftY,
                patches = patches
            )
        }.getOrNull()
    }

    private fun validate(frame: FallbackDeltaFrame) {
        require(frame.frameId > 0L)
        require(frame.baseFrameId in 0 until frame.frameId)
        require(frame.width in 2..4096)
        require(frame.height in 2..4096)
        require(frame.rotation in setOf(0, 90, 180, 270))
        require(frame.shiftX in -4096..4096)
        require(frame.shiftY in -4096..4096)
        require(frame.patches.size in 1..MAX_PATCHES)
        frame.patches.forEach { patch ->
            require(patch.x >= 0 && patch.y >= 0)
            require(patch.width > 0 && patch.height > 0)
            require(patch.x + patch.width <= frame.width)
            require(patch.y + patch.height <= frame.height)
            require(patch.jpeg.isNotEmpty())
        }
    }

    class Reassembler {
        private var activeFrameId = -1L
        private var chunks: Array<ByteArray?> = emptyArray()
        private var totalBytes = 0
        private var received = 0

        fun offer(bytes: ByteArray): FallbackDeltaFrame? {
            val chunk = decodeChunk(bytes) ?: return null
            if (chunk.frameId < activeFrameId) return null

            if (chunk.frameId > activeFrameId) {
                activeFrameId = chunk.frameId
                chunks = arrayOfNulls(chunk.count)
                totalBytes = 0
                received = 0
            }

            if (chunk.count != chunks.size) {
                resetAssemblyKeepFrameId()
                return null
            }
            if (chunks[chunk.index] != null) return null
            if (totalBytes + chunk.payload.size > MAX_UPDATE_BYTES) {
                resetAssemblyKeepFrameId()
                return null
            }

            chunks[chunk.index] = chunk.payload
            totalBytes += chunk.payload.size
            received += 1
            if (received != chunks.size) return null

            val payload = ByteArray(totalBytes)
            var offset = 0
            chunks.forEach { part ->
                val data = part ?: return null
                data.copyInto(payload, offset)
                offset += data.size
            }

            val result = decodePayload(activeFrameId, payload)
            resetAssemblyKeepFrameId()
            return result
        }

        fun reset() {
            activeFrameId = -1L
            resetAssemblyKeepFrameId()
        }

        private fun resetAssemblyKeepFrameId() {
            chunks = emptyArray()
            totalBytes = 0
            received = 0
        }
    }
}
