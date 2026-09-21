package com.aaris.shield.network

import java.util.concurrent.atomic.AtomicInteger

/** IPv4/UDP packet handling for the DNS-only TUN route. */
object Ipv4UdpPacketCodec {
    private const val IPV4_MIN_HEADER = 20
    private const val UDP_HEADER = 8
    private const val PROTOCOL_UDP = 17
    private const val DNS_PORT = 53
    private const val MAX_DNS_PAYLOAD = 8192
    private val nextIdentification = AtomicInteger(1)

    data class DnsDatagram(
        val clientAddress: ByteArray,
        val clientPort: Int,
        val dnsPayload: ByteArray,
    )

    fun parseDnsQuery(packet: ByteArray, length: Int, dnsAddress: ByteArray): DnsDatagram? {
        if (length < IPV4_MIN_HEADER + UDP_HEADER || dnsAddress.size != 4) return null
        val versionAndIhl = packet[0].toInt() and 0xff
        if ((versionAndIhl ushr 4) != 4) return null
        val ihl = (versionAndIhl and 0x0f) * 4
        if (ihl < IPV4_MIN_HEADER || ihl + UDP_HEADER > length) return null

        val totalLength = u16(packet, 2)
        if (totalLength > length || totalLength < ihl + UDP_HEADER) return null
        if ((packet[9].toInt() and 0xff) != PROTOCOL_UDP) return null

        val fragment = u16(packet, 6)
        if ((fragment and 0x3fff) != 0) return null
        for (index in 0..3) {
            if (packet[16 + index] != dnsAddress[index]) return null
        }

        val udpOffset = ihl
        val destinationPort = u16(packet, udpOffset + 2)
        if (destinationPort != DNS_PORT) return null
        val udpLength = u16(packet, udpOffset + 4)
        if (udpLength < UDP_HEADER || udpOffset + udpLength > totalLength) return null

        val payloadLength = udpLength - UDP_HEADER
        if (payloadLength <= 0 || payloadLength > MAX_DNS_PAYLOAD) return null

        return DnsDatagram(
            clientAddress = packet.copyOfRange(12, 16),
            clientPort = u16(packet, udpOffset),
            dnsPayload = packet.copyOfRange(udpOffset + UDP_HEADER, udpOffset + udpLength),
        )
    }

    fun buildDnsResponse(
        dnsAddress: ByteArray,
        clientAddress: ByteArray,
        clientPort: Int,
        dnsPayload: ByteArray,
    ): ByteArray? {
        if (dnsAddress.size != 4 || clientAddress.size != 4) return null
        if (clientPort !in 1..65535 || dnsPayload.isEmpty() || dnsPayload.size > MAX_DNS_PAYLOAD) return null

        val totalLength = IPV4_MIN_HEADER + UDP_HEADER + dnsPayload.size
        if (totalLength > 65535) return null
        val result = ByteArray(totalLength)

        result[0] = 0x45
        result[1] = 0
        putU16(result, 2, totalLength)
        putU16(result, 4, nextIdentification.getAndIncrement() and 0xffff)
        putU16(result, 6, 0x4000) // Don't fragment: this is a local virtual link.
        result[8] = 64
        result[9] = PROTOCOL_UDP.toByte()
        dnsAddress.copyInto(result, 12)
        clientAddress.copyInto(result, 16)
        putU16(result, 10, ipv4HeaderChecksum(result))

        val udpOffset = IPV4_MIN_HEADER
        putU16(result, udpOffset, DNS_PORT)
        putU16(result, udpOffset + 2, clientPort)
        putU16(result, udpOffset + 4, UDP_HEADER + dnsPayload.size)
        putU16(result, udpOffset + 6, 0) // Valid for IPv4 UDP; avoids faulty pseudo-header math.
        dnsPayload.copyInto(result, udpOffset + UDP_HEADER)
        return result
    }

    private fun ipv4HeaderChecksum(header: ByteArray): Int {
        var sum = 0L
        var offset = 0
        while (offset < IPV4_MIN_HEADER) {
            if (offset == 10) {
                offset += 2
                continue
            }
            sum += u16(header, offset).toLong()
            while (sum > 0xffff) sum = (sum and 0xffff) + (sum ushr 16)
            offset += 2
        }
        return sum.inv().toInt() and 0xffff
    }

    private fun u16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

    private fun putU16(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = (value ushr 8).toByte()
        bytes[offset + 1] = value.toByte()
    }
}
