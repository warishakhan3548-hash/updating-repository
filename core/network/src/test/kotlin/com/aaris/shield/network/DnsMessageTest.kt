package com.aaris.shield.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DnsMessageTest {
    @Test
    fun parsesQuestionAndBuildsNxdomainWithoutEchoingAdditionalRecords() {
        val query = query("blocked.example")
        assertEquals("blocked.example", DnsMessage.firstQuestion(query)?.name)
        val response = requireNotNull(DnsMessage.nxdomainResponse(query))
        assertEquals(3, response[3].toInt() and 0x0f)
        assertEquals(query[0], response[0])
        assertEquals(query[1], response[1])
    }

    @Test
    fun discoversCnameAliasTargets() {
        val query = query("start.example")
        val answer = cnameResponse(query, "blocked.example")
        assertTrue(DnsMessage.isMatchingResponse(query, answer))
        assertEquals(listOf("blocked.example"), DnsMessage.aliasTargets(answer))
    }

    private fun query(name: String): ByteArray {
        val encodedName = encodeName(name)
        val message = ByteArray(12 + encodedName.size + 4)
        message[0] = 0x12
        message[1] = 0x34
        message[2] = 0x01
        message[5] = 0x01
        encodedName.copyInto(message, 12)
        val tail = 12 + encodedName.size
        message[tail + 1] = 0x01
        message[tail + 3] = 0x01
        return message
    }

    private fun cnameResponse(query: ByteArray, target: String): ByteArray {
        val targetBytes = encodeName(target)
        val response = query.copyOf(query.size + 12 + targetBytes.size)
        response[2] = 0x81.toByte()
        response[3] = 0x80.toByte()
        response[7] = 0x01
        var offset = query.size
        response[offset++] = 0xc0.toByte()
        response[offset++] = 0x0c
        response[offset++] = 0x00
        response[offset++] = 0x05
        response[offset++] = 0x00
        response[offset++] = 0x01
        response[offset++] = 0x00
        response[offset++] = 0x00
        response[offset++] = 0x00
        response[offset++] = 0x3c
        response[offset++] = (targetBytes.size ushr 8).toByte()
        response[offset++] = targetBytes.size.toByte()
        targetBytes.copyInto(response, offset)
        return response
    }

    private fun encodeName(name: String): ByteArray {
        val result = ArrayList<Byte>()
        for (label in name.split('.')) {
            result += label.length.toByte()
            label.toByteArray(Charsets.US_ASCII).forEach(result::add)
        }
        result += 0
        return result.toByteArray()
    }
}
