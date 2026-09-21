package com.aaris.shield.network

/**
 * Minimal defensive DNS wire parser used only for policy enforcement. It does
 * not try to be a general resolver. Every length, pointer and count is bounded
 * before use so malformed network input fails closed instead of escaping the
 * domain policy or allocating unbounded memory.
 */
object DnsMessageCodec {
    private const val HEADER_SIZE = 12
    private const val TYPE_CNAME = 5
    private const val TYPE_DNAME = 39
    private const val TYPE_SVCB = 64
    private const val TYPE_HTTPS = 65
    private const val MAX_NAME_JUMPS = 32
    private const val MAX_RR_COUNT = 512

    enum class ResponseInspection {
        SAFE,
        BLOCKED_REDIRECT,
        MALFORMED,
    }

    data class Question(
        val name: String,
        val type: Int,
        val clazz: Int,
        val endOffset: Int,
    )

    fun readSingleQuestion(message: ByteArray): Question? {
        if (message.size < HEADER_SIZE) return null
        if (u16(message, 4) != 1) return null

        return try {
            val decoded = readName(message, HEADER_SIZE, message.size)
            if (decoded.nextOffset + 4 > message.size) return null
            Question(
                name = decoded.name,
                type = u16(message, decoded.nextOffset),
                clazz = u16(message, decoded.nextOffset + 2),
                endOffset = decoded.nextOffset + 4,
            )
        } catch (_: MalformedDnsException) {
            null
        }
    }

    fun isResponseFor(query: ByteArray, response: ByteArray): Boolean {
        if (query.size < HEADER_SIZE || response.size < HEADER_SIZE) return false
        if (query[0] != response[0] || query[1] != response[1]) return false
        return (u16(response, 2) and 0x8000) != 0
    }

    fun isTruncated(response: ByteArray): Boolean =
        response.size >= HEADER_SIZE && (u16(response, 2) and 0x0200) != 0

    fun buildErrorResponse(query: ByteArray, rcode: Int): ByteArray? {
        if (rcode !in 0..15) return null
        val question = readSingleQuestion(query) ?: return null
        val response = query.copyOfRange(0, question.endOffset)
        val queryFlags = u16(query, 2)
        val flags = 0x8000 or // QR
            (queryFlags and 0x7800) or // opcode
            (queryFlags and 0x0100) or // RD
            0x0080 or // RA
            (queryFlags and 0x0010) or // CD
            rcode
        putU16(response, 2, flags)
        putU16(response, 4, 1)
        putU16(response, 6, 0)
        putU16(response, 8, 0)
        putU16(response, 10, 0)
        return response
    }

    /**
     * Inspect alias-like response records that can redirect an allowed query
     * toward another hostname. Unknown record types are left untouched.
     */
    fun inspectResponse(response: ByteArray, policy: DomainPolicy): ResponseInspection {
        if (response.size < HEADER_SIZE || (u16(response, 2) and 0x8000) == 0) {
            return ResponseInspection.MALFORMED
        }

        return try {
            val qd = boundedCount(u16(response, 4))
            val an = boundedCount(u16(response, 6))
            val ns = boundedCount(u16(response, 8))
            val ar = boundedCount(u16(response, 10))

            var offset = HEADER_SIZE
            repeat(qd) {
                val name = readName(response, offset, response.size)
                offset = name.nextOffset
                if (offset + 4 > response.size) throw MalformedDnsException()
                offset += 4
            }

            val totalRecords = an + ns + ar
            repeat(totalRecords) {
                val owner = readName(response, offset, response.size)
                offset = owner.nextOffset
                if (offset + 10 > response.size) throw MalformedDnsException()

                val type = u16(response, offset)
                val rdLength = u16(response, offset + 8)
                val rdataStart = offset + 10
                val rdataEnd = rdataStart + rdLength
                if (rdataEnd > response.size) throw MalformedDnsException()

                val target = when (type) {
                    TYPE_CNAME, TYPE_DNAME -> readName(response, rdataStart, rdataEnd).name
                    TYPE_SVCB, TYPE_HTTPS -> {
                        if (rdLength < 3) throw MalformedDnsException()
                        readName(response, rdataStart + 2, rdataEnd).name
                    }
                    else -> null
                }

                if (target != null && policy.isBlocked(target)) {
                    return ResponseInspection.BLOCKED_REDIRECT
                }
                offset = rdataEnd
            }
            ResponseInspection.SAFE
        } catch (_: MalformedDnsException) {
            ResponseInspection.MALFORMED
        }
    }

    private data class DecodedName(val name: String, val nextOffset: Int)

    private fun readName(message: ByteArray, start: Int, encodedEnd: Int): DecodedName {
        if (start !in message.indices || encodedEnd > message.size || start >= encodedEnd) {
            throw MalformedDnsException()
        }

        val labels = ArrayList<String>(8)
        var cursor = start
        var nextOffset = -1
        var jumps = 0
        val seenPointers = HashSet<Int>()

        while (true) {
            if (cursor !in message.indices) throw MalformedDnsException()
            val length = message[cursor].toInt() and 0xff

            when {
                length == 0 -> {
                    if (nextOffset < 0) {
                        if (cursor >= encodedEnd) throw MalformedDnsException()
                        nextOffset = cursor + 1
                    }
                    break
                }

                (length and 0xC0) == 0xC0 -> {
                    if (cursor + 1 >= message.size) throw MalformedDnsException()
                    if (nextOffset < 0 && cursor + 2 > encodedEnd) throw MalformedDnsException()
                    val pointer = ((length and 0x3f) shl 8) or (message[cursor + 1].toInt() and 0xff)
                    if (pointer >= message.size || !seenPointers.add(pointer) || ++jumps > MAX_NAME_JUMPS) {
                        throw MalformedDnsException()
                    }
                    if (nextOffset < 0) nextOffset = cursor + 2
                    cursor = pointer
                }

                (length and 0xC0) != 0 -> throw MalformedDnsException()

                else -> {
                    if (length > 63) throw MalformedDnsException()
                    val labelStart = cursor + 1
                    val labelEnd = labelStart + length
                    if (labelEnd > message.size) throw MalformedDnsException()
                    if (nextOffset < 0 && labelEnd > encodedEnd) throw MalformedDnsException()
                    val label = buildString(length) {
                        for (index in labelStart until labelEnd) {
                            val b = message[index].toInt() and 0xff
                            if (b !in 0x21..0x7e) throw MalformedDnsException()
                            append(b.toChar())
                        }
                    }
                    labels += label
                    if (labels.sumOf { it.length } + labels.size - 1 > 253) throw MalformedDnsException()
                    cursor = labelEnd
                }
            }
        }

        if (nextOffset < 0) throw MalformedDnsException()
        return DecodedName(labels.joinToString("."), nextOffset)
    }

    private fun boundedCount(value: Int): Int {
        if (value > MAX_RR_COUNT) throw MalformedDnsException()
        return value
    }

    private fun u16(bytes: ByteArray, offset: Int): Int {
        if (offset < 0 || offset + 1 >= bytes.size) throw MalformedDnsException()
        return ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)
    }

    private fun putU16(bytes: ByteArray, offset: Int, value: Int) {
        if (offset < 0 || offset + 1 >= bytes.size) throw MalformedDnsException()
        bytes[offset] = (value ushr 8).toByte()
        bytes[offset + 1] = value.toByte()
    }

    private class MalformedDnsException : RuntimeException()
}
