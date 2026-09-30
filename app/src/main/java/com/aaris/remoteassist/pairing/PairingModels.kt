package com.aaris.remoteassist.pairing

data class ShareTicket(
    val sessionId: String,
    val code: String,
    val expiresAtEpochMs: Long
)

data class PairRequest(
    val sessionId: String,
    val hostUid: String,
    val controllerUid: String?
)

object PairingCode {
    private val nonDigits = Regex("\\D")

    fun normalize(raw: String): String? {
        val digits = raw.replace(nonDigits, "")
        return digits.takeIf { it.length == 6 }
    }

    fun display(code: String): String {
        require(code.length == 6 && code.all(Char::isDigit))
        return code.take(3) + " " + code.drop(3)
    }
}
