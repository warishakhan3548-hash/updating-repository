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
    private val embeddedCandidate =
        Regex("(?<!\\d)(\\d{4}[\\s-]?\\d{4}[\\s-]?\\d{4})(?!\\d)")

    fun normalize(raw: String): String? {
        val digits = raw.replace(nonDigits, "")
        return digits.takeIf { it.length == DIGITS }
    }

    fun extract(raw: String): String? {
        normalize(raw)?.let { return it }

        val candidates = embeddedCandidate
            .findAll(raw)
            .mapNotNull { match ->
                normalize(match.groupValues[1])
            }
            .distinct()
            .take(2)
            .toList()

        return candidates.singleOrNull()
    }

    fun display(code: String): String {
        require(code.length == DIGITS && code.all(Char::isDigit))
        return code.chunked(4).joinToString(" ")
    }

    const val DIGITS = 12
}

object PairingLink {
    private const val PREFIX = "aarisremote://connect?"

    fun uri(code: String): String {
        val normalized = PairingCode.normalize(code)
            ?: error("Pairing code must contain " + PairingCode.DIGITS + " digits")
        return PREFIX + "code=" + normalized
    }

    fun parse(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        if (!raw.startsWith(PREFIX, ignoreCase = true)) return null

        val query = raw.substringAfter('?', "")
        val encodedCode = query
            .split('&')
            .asSequence()
            .mapNotNull { part ->
                val separator = part.indexOf('=')
                if (separator <= 0) {
                    null
                } else {
                    part.substring(0, separator) to
                        part.substring(separator + 1)
                }
            }
            .firstOrNull { (key, _) ->
                key.equals("code", ignoreCase = true)
            }
            ?.second
            ?: return null

        return PairingCode.normalize(encodedCode)
    }
}
