package com.aaris.shield.network

import java.net.Inet4Address
import java.net.InetAddress

data class Ipv4UdpPacket(
    val sourceAddress: Inet4Address,
    val destinationAddress: Inet4Address,
    val sourcePort: Int,
    val destinationPort: Int,
    val payload: ByteArray,
) {
    companion object {
        fun parse(packet: ByteArray, length: Int): Ipv4UdpPacket? {
            if (length < 28 || length > packet.size) return null
            val version = (packet[0].toInt() ushr 4) and 0x0f
            val ihl = (packet[0].toInt() and 0x0f) * 4
            if (version != 4 || ihl < 20 || ihl + 8 > length) return null
            val totalLength = readU16(packet, 2)
            if (totalLength < ihl + 8 || totalLength > length) return null
            if ((packet[9].toInt() and 0xff) != 17) return null
            val fragmentField = readU16(packet, 6)
            if ((fragmentField and 0x3fff) != 0) return null

            val udpLength = readU16(packet, ihl + 4)
            if (udpLength < 8 || ihl + udpLength > totalLength) return null
            val sourceAddress = InetAddress.getByAddress(packet.copyOfRange(12, 16)) as? Inet4Address ?: return null
            val destinationAddress = InetAddress.getByAddress(packet.copyOfRange(16, 20)) as? Inet4Address ?: return null
            return Ipv4UdpPacket(
                sourceAddress = sourceAddress,
                destinationAddress = destinationAddress,
                sourcePort = readU16(packet, ihl),
                destinationPort = readU16(packet, ihl + 2),
                payload = packet.copyOfRange(ihl + 8, ihl + udpLength),
            )
        }

        fun buildResponse(request: Ipv4UdpPacket, payload: ByteArray): ByteArray {
            val ipHeaderLength = 20
            val udpLength = 8 + payload.size
            val totalLength = ipHeaderLength + udpLength
            require(totalLength <= 65_535) { "UDP payload too large" }
            val packet = ByteArray(totalLength)
            packet[0] = 0x45
            packet[1] = 0
            writeU16(packet, 2, totalLength)
            writeU16(packet, 4, 0)
            writeU16(packet, 6, 0x4000)
            packet[8] = 64
            packet[9] = 17
            request.destinationAddress.address.copyInto(packet, 12)
            request.sourceAddress.address.copyInto(packet, 16)
            writeU16(packet, 10, checksum(packet, 0, ipHeaderLength))

            val udpOffset = ipHeaderLength
            writeU16(packet, udpOffset, request.destinationPort)
            writeU16(packet, udpOffset + 2, request.sourcePort)
            writeU16(packet, udpOffset + 4, udpLength)
            writeU16(packet, udpOffset + 6, 0)
            payload.copyInto(packet, udpOffset + 8)
            val udpChecksum = udpChecksum(packet, udpOffset, udpLength)
            writeU16(packet, udpOffset + 6, if (udpChecksum == 0) 0xffff else udpChecksum)
            return packet
        }

        private fun udpChecksum(packet: ByteArray, udpOffset: Int, udpLength: Int): Int {
            var sum = 0L
            sum = addBytes(sum, packet, 12, 8)
            sum += 17
            sum += udpLength
            sum = addBytes(sum, packet, udpOffset, udpLength)
            return finalizeChecksum(sum)
        }

        private fun checksum(bytes: ByteArray, offset: Int, length: Int): Int =
            finalizeChecksum(addBytes(0, bytes, offset, length))

        private fun addBytes(initial: Long, bytes: ByteArray, offset: Int, length: Int): Long {
            var sum = initial
            var index = offset
            val end = offset + length
            while (index + 1 < end) {
                sum += ((bytes[index].toInt() and 0xff) shl 8) or (bytes[index + 1].toInt() and 0xff)
                index += 2
            }
            if (index < end) sum += (bytes[index].toInt() and 0xff) shl 8
            return sum
        }

        private fun finalizeChecksum(input: Long): Int {
            var sum = input
            while ((sum ushr 16) != 0L) {
                sum = (sum and 0xffff) + (sum ushr 16)
            }
            return sum.inv().toInt() and 0xffff
        }

        private fun readU16(bytes: ByteArray, offset: Int): Int =
            ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

        private fun writeU16(bytes: ByteArray, offset: Int, value: Int) {
            bytes[offset] = (value ushr 8).toByte()
            bytes[offset + 1] = value.toByte()
        }
    }
}
