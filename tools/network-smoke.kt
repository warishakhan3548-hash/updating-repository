import com.aaris.shield.network.DomainDecision
import com.aaris.shield.network.DomainPolicy
import com.aaris.shield.network.DnsMessage
import com.aaris.shield.network.Ipv4UdpPacket
import java.net.InetAddress

private fun query(name: String): ByteArray {
    val parts = name.split('.')
    val body = ArrayList<Byte>()
    for (part in parts) {
        body += part.length.toByte()
        part.toByteArray(Charsets.US_ASCII).forEach(body::add)
    }
    body += 0
    val result = ByteArray(12 + body.size + 4)
    result[0] = 0x12
    result[1] = 0x34
    result[2] = 0x01
    result[5] = 0x01
    body.toByteArray().copyInto(result, 12)
    val tail = 12 + body.size
    result[tail + 1] = 0x01
    result[tail + 3] = 0x01
    return result
}

fun main() {
    val policy = DomainPolicy.fromLines(
        blocked = sequenceOf("blocked.example", "0.0.0.0 second.example"),
        allowed = sequenceOf("safe.blocked.example"),
    )
    check(policy.decide("www.blocked.example.") == DomainDecision.BLOCK)
    check(policy.decide("safe.blocked.example") == DomainDecision.ALLOW)
    check(policy.decide("notblocked.example") == DomainDecision.ALLOW)

    val dnsQuery = query("blocked.example")
    check(DnsMessage.firstQuestion(dnsQuery)?.name == "blocked.example")
    val denied = checkNotNull(DnsMessage.nxdomainResponse(dnsQuery))
    check((denied[3].toInt() and 0x0f) == 3)
    check(denied[0] == dnsQuery[0] && denied[1] == dnsQuery[1])

    val cname = dnsQuery.copyOf(dnsQuery.size + 29).also { response ->
        response[2] = 0x81.toByte()
        response[3] = 0x80.toByte()
        response[7] = 0x01
        var o = dnsQuery.size
        response[o++] = 0xc0.toByte(); response[o++] = 0x0c
        response[o++] = 0x00; response[o++] = 0x05
        response[o++] = 0x00; response[o++] = 0x01
        response[o++] = 0x00; response[o++] = 0x00; response[o++] = 0x00; response[o++] = 0x3c
        response[o++] = 0x00; response[o++] = 0x11
        response[o++] = 0x07
        "blocked".toByteArray().forEach { response[o++] = it }
        response[o++] = 0x07
        "example".toByteArray().forEach { response[o++] = it }
        response[o] = 0x00
    }
    check(DnsMessage.isMatchingResponse(dnsQuery, cname))
    check(DnsMessage.aliasTargets(cname) == listOf("blocked.example"))

    val request = Ipv4UdpPacket(
        sourceAddress = InetAddress.getByName("10.111.222.2") as java.net.Inet4Address,
        destinationAddress = InetAddress.getByName("10.111.222.1") as java.net.Inet4Address,
        sourcePort = 53000,
        destinationPort = 53,
        payload = dnsQuery,
    )
    val wire = Ipv4UdpPacket.buildResponse(request, denied)
    val parsed = checkNotNull(Ipv4UdpPacket.parse(wire, wire.size))
    check(parsed.sourcePort == 53 && parsed.destinationPort == 53000)
    check(parsed.sourceAddress.hostAddress == "10.111.222.1")
    check(parsed.destinationAddress.hostAddress == "10.111.222.2")
    check(parsed.payload.contentEquals(denied))

    println("Aaris Shield network smoke checks: PASS")
}
