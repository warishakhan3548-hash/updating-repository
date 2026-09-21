package com.aaris.shield.network

import android.net.VpnService
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress

internal class ProtectedDnsClient(
    private val vpnService: VpnService,
    private val tracker: UnderlyingDnsTracker,
) {
    fun query(payload: ByteArray): ByteArray? {
        val snapshot = tracker.snapshot() ?: return null
        for (server in snapshot.dnsServers.take(MAX_UPSTREAM_SERVERS)) {
            val answer = runCatching {
                DatagramSocket().use { socket ->
                    socket.soTimeout = UPSTREAM_TIMEOUT_MS
                    check(vpnService.protect(socket)) { "Unable to protect upstream DNS socket" }
                    snapshot.network.bindSocket(socket)
                    socket.connect(InetSocketAddress(server, DNS_PORT))
                    socket.send(DatagramPacket(payload, payload.size))
                    val buffer = ByteArray(MAX_DNS_MESSAGE_BYTES)
                    val response = DatagramPacket(buffer, buffer.size)
                    socket.receive(response)
                    buffer.copyOf(response.length)
                }
            }.getOrNull()
            if (answer != null && DnsMessage.isMatchingResponse(payload, answer)) return answer
        }
        return null
    }

    private companion object {
        const val DNS_PORT = 53
        const val UPSTREAM_TIMEOUT_MS = 1_200
        const val MAX_UPSTREAM_SERVERS = 3
        const val MAX_DNS_MESSAGE_BYTES = 4_096
    }
}
