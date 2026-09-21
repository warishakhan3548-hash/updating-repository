package com.aaris.shield.network

import java.net.Inet4Address
import java.net.InetAddress
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class Ipv4UdpPacketTest {
    @Test
    fun responseSwapsEndpointsAndRoundTripsPayload() {
        val request = Ipv4UdpPacket(
            sourceAddress = InetAddress.getByName("10.111.222.2") as Inet4Address,
            destinationAddress = InetAddress.getByName("10.111.222.1") as Inet4Address,
            sourcePort = 53000,
            destinationPort = 53,
            payload = byteArrayOf(1, 2, 3, 4),
        )
        val wire = Ipv4UdpPacket.buildResponse(request, byteArrayOf(9, 8, 7))
        val parsed = requireNotNull(Ipv4UdpPacket.parse(wire, wire.size))
        assertEquals("10.111.222.1", parsed.sourceAddress.hostAddress)
        assertEquals("10.111.222.2", parsed.destinationAddress.hostAddress)
        assertEquals(53, parsed.sourcePort)
        assertEquals(53000, parsed.destinationPort)
        assertArrayEquals(byteArrayOf(9, 8, 7), parsed.payload)
    }
}
