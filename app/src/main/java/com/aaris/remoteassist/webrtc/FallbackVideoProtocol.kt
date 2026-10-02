package com.aaris.remoteassist.webrtc

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class FallbackVideoFrame(
    val frameId: Long,
    val width: Int,
    val height: Int,
    val rotation: Int,
    val jpeg: ByteArray
)

private data class FallbackVideoChunk(
    val frameId: Long,
    val chunkIndex: Int,
    val chunkCount: Int,
    val width: Int,
    val height: Int,
    val rotation: Int,
    val payload: ByteArray
)

object FallbackVideoProtocol {
    private const val MAGIC = 0x41524631 // "ARF1"
    private const val HEADER_BYTES = 24
    private const val MAX_CHUNK_PAYLOAD = 12_000
    private const val MAX_CHUNKS = 64
    private const val MAX_FRAME_BYTES = 700_000

    fun encodeFrame(
        frameId: Long,
        width: Int,
        height: Int,
        rotation: Int,
        jpeg: ByteArray
    ): List<ByteArray> {
        require(width in 2..4096)
        require(height in 2..4096)
        require(rotation in setOf(0, 90, 180, 270))
        require(jpeg.isNotEmpty() && jpeg.size <= MAX_FRAME_BYTES)

        val count =
            (jpeg.size + MAX_CHUNK_PAYLOAD - 1) /
                MAX_CHUNK_PAYLOAD
        require(count in 1..MAX_CHUNKS)

        return List(count) { index ->
            val start = index * MAX_CHUNK_PAYLOAD
            val length =
                minOf(
                    MAX_CHUNK_PAYLOAD,
                    jpeg.size - start
                )

            ByteBuffer
                .allocate(HEADER_BYTES + length)
                .order(ByteOrder.BIG_ENDIAN)
                .apply {
                    putInt(MAGIC)
                    putLong(frameId)
                    putShort(index.toShort())
                    putShort(count.toShort())
                    putShort(width.toShort())
                    putShort(height.toShort())
                    putShort(rotation.toShort())
                    putShort(length.toShort())
                    put(jpeg, start, length)
                }
                .array()
        }
    }

    internal fun decodeChunk(
        bytes: ByteArray
    ): FallbackVideoChunk? {
        if (bytes.size < HEADER_BYTES) return null

        return runCatching {
            val buffer =
                ByteBuffer.wrap(bytes)
                    .order(ByteOrder.BIG_ENDIAN)

            if (buffer.int != MAGIC) return null

            val frameId = buffer.long
            val index = buffer.short.toInt() and 0xffff
            val count = buffer.short.toInt() and 0xffff
            val width = buffer.short.toInt() and 0xffff
            val height = buffer.short.toInt() and 0xffff
            val rotation = buffer.short.toInt() and 0xffff
            val length = buffer.short.toInt() and 0xffff

            require(frameId >= 0L)
            require(count in 1..MAX_CHUNKS)
            require(index in 0 until count)
            require(width in 2..4096)
            require(height in 2..4096)
            require(rotation in setOf(0, 90, 180, 270))
            require(length in 1..MAX_CHUNK_PAYLOAD)
            require(buffer.remaining() == length)

            val payload = ByteArray(length)
            buffer.get(payload)

            FallbackVideoChunk(
                frameId = frameId,
                chunkIndex = index,
                chunkCount = count,
                width = width,
                height = height,
                rotation = rotation,
                payload = payload
            )
        }.getOrNull()
    }

    class Reassembler {
        private var activeFrameId = -1L
        private var width = 0
        private var height = 0
        private var rotation = 0
        private var chunks: Array<ByteArray?> = emptyArray()
        private var totalBytes = 0
        private var received = 0

        fun offer(bytes: ByteArray): FallbackVideoFrame? {
            val chunk = decodeChunk(bytes) ?: return null

            if (chunk.frameId < activeFrameId) {
                return null
            }

            if (chunk.frameId > activeFrameId) {
                activeFrameId = chunk.frameId
                width = chunk.width
                height = chunk.height
                rotation = chunk.rotation
                chunks = arrayOfNulls(chunk.chunkCount)
                totalBytes = 0
                received = 0
            }

            if (
                chunk.chunkCount != chunks.size ||
                chunk.width != width ||
                chunk.height != height ||
                chunk.rotation != rotation
            ) {
                reset()
                return null
            }

            if (chunks[chunk.chunkIndex] != null) {
                return null
            }

            if (
                totalBytes + chunk.payload.size >
                MAX_FRAME_BYTES
            ) {
                reset()
                return null
            }

            chunks[chunk.chunkIndex] = chunk.payload
            totalBytes += chunk.payload.size
            received += 1

            if (received != chunks.size) {
                return null
            }

            val jpeg = ByteArray(totalBytes)
            var offset = 0
            chunks.forEach { part ->
                val data = part ?: return null
                data.copyInto(
                    destination = jpeg,
                    destinationOffset = offset
                )
                offset += data.size
            }

            val frame = FallbackVideoFrame(
                frameId = activeFrameId,
                width = width,
                height = height,
                rotation = rotation,
                jpeg = jpeg
            )

            // Keep the last frame id so stale chunks remain rejected.
            chunks = emptyArray()
            totalBytes = 0
            received = 0
            return frame
        }

        fun reset() {
            activeFrameId = -1L
            width = 0
            height = 0
            rotation = 0
            chunks = emptyArray()
            totalBytes = 0
            received = 0
        }
    }
}
