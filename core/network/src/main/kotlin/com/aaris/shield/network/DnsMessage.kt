package com.aaris.shield.network

data class DnsQuestion(
    val name: String,
    val type: Int,
    val dnsClass: Int,
    val encodedEnd: Int,
)

object DnsMessage {
    private const val HEADER_SIZE = 12
    private const val MAX_POINTER_JUMPS = 16

    fun firstQuestion(message: ByteArray): DnsQuestion? {
        if (message.size < HEADER_SIZE) return null
        val flags = readU16(message, 2)
        if ((flags and 0x8000) != 0) return null
        if (readU16(message, 4) != 1) return null

        val decoded = decodeName(message, HEADER_SIZE) ?: return null
        val typeOffset = decoded.nextOffset
        if (typeOffset + 4 > message.size) return null
        return DnsQuestion(
            name = decoded.name,
            type = readU16(message, typeOffset),
            dnsClass = readU16(message, typeOffset + 2),
            encodedEnd = typeOffset + 4,
        )
    }

    fun nxdomainResponse(query: ByteArray): ByteArray? = errorResponse(query, rcode = 3)

    fun servfailResponse(query: ByteArray): ByteArray? = errorResponse(query, rcode = 2)

    fun aliasTargets(message: ByteArray): List<String>? {
        if (message.size < HEADER_SIZE) return null
        if ((readU16(message, 2) and 0x8000) == 0) return null
        val questionCount = readU16(message, 4)
        val answerCount = readU16(message, 6)
        if (questionCount > 8 || answerCount > 128) return null

        var cursor = HEADER_SIZE
        repeat(questionCount) {
            val name = decodeName(message, cursor) ?: return null
            cursor = name.nextOffset
            if (cursor + 4 > message.size) return null
            cursor += 4
        }

        val aliases = ArrayList<String>()
        repeat(answerCount) {
            val owner = decodeName(message, cursor) ?: return null
            cursor = owner.nextOffset
            if (cursor + 10 > message.size) return null
            val type = readU16(message, cursor)
            val rdLength = readU16(message, cursor + 8)
            val rdata = cursor + 10
            val rdataEnd = rdata + rdLength
            if (rdataEnd > message.size) return null

            val aliasOffset = when (type) {
                5, 39 -> rdata
                64, 65 -> if (rdLength >= 3) rdata + 2 else -1
                else -> -1
            }
            if (aliasOffset >= 0) {
                val decoded = decodeName(message, aliasOffset) ?: return null
                if (decoded.name.isNotEmpty()) aliases += decoded.name
            }
            cursor = rdataEnd
        }
        return aliases
    }

    fun isMatchingResponse(query: ByteArray, response: ByteArray): Boolean {
        if (query.size < HEADER_SIZE || response.size < HEADER_SIZE) return false
        if (query[0] != response[0] || query[1] != response[1]) return false
        return (readU16(response, 2) and 0x8000) != 0
    }

    private fun errorResponse(query: ByteArray, rcode: Int): ByteArray? {
        val question = firstQuestion(query) ?: return null
        val response = query.copyOfRange(0, question.encodedEnd)
        val requestFlags = readU16(query, 2)
        val opcode = requestFlags and 0x7800
        val recursionDesired = requestFlags and 0x0100
        val flags = 0x8000 or opcode or recursionDesired or 0x0080 or rcode
        writeU16(response, 2, flags)
        writeU16(response, 4, 1)
        writeU16(response, 6, 0)
        writeU16(response, 8, 0)
        writeU16(response, 10, 0)
        return response
    }

    private data class DecodedName(val name: String, val nextOffset: Int)

    private fun decodeName(message: ByteArray, startOffset: Int): DecodedName? {
        val labels = ArrayList<String>(8)
        var cursor = startOffset
        var nextOffset = -1
        var pointerJumps = 0
        val visited = HashSet<Int>()

        while (true) {
            if (cursor !in message.indices) return null
            val length = message[cursor].toInt() and 0xff
            when {
                length == 0 -> {
                    if (nextOffset < 0) nextOffset = cursor + 1
                    break
                }
                (length and 0xc0) == 0xc0 -> {
                    if (cursor + 1 >= message.size || pointerJumps++ >= MAX_POINTER_JUMPS) return null
                    val pointer = ((length and 0x3f) shl 8) or (message[cursor + 1].toInt() and 0xff)
                    if (pointer >= message.size || !visited.add(pointer)) return null
                    if (nextOffset < 0) nextOffset = cursor + 2
                    cursor = pointer
                }
                (length and 0xc0) != 0 || length > 63 -> return null
                else -> {
                    val labelStart = cursor + 1
                    val labelEnd = labelStart + length
                    if (labelEnd > message.size) return null
                    val label = String(message, labelStart, length, Charsets.US_ASCII)
                    if (label.any { it.code < 0x21 || it.code > 0x7e }) return null
                    labels += label
                    cursor = labelEnd
                }
            }
        }

        val name = labels.joinToString(".")
        if (name.isEmpty() || nextOffset < 0) return null
        return DecodedName(name, nextOffset)
    }

    private fun readU16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

    private fun writeU16(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = (value ushr 8).toByte()
        bytes[offset + 1] = value.toByte()
    }
}
