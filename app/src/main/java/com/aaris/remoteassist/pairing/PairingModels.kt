package com.aaris.remoteassist.pairing

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

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
    private const val SCHEME = "aarisremote"
    private const val HOST = "connect"

    fun uri(code: String): String {
        val normalized = PairingCode.normalize(code)
            ?: error("Pairing code must contain " + PairingCode.DIGITS + " digits")
        return "$SCHEME://$HOST?code=$normalized"
    }

    fun parse(raw: String?): String? {
        if (raw.isNullOrBlank()) return null

        val parsed = runCatching {
            URI(raw.trim())
        }.getOrNull() ?: return null

        if (
            !parsed.scheme.equals(SCHEME, ignoreCase = true) ||
            !parsed.host.equals(HOST, ignoreCase = true)
        ) {
            return null
        }

        val path = parsed.rawPath.orEmpty()
        if (path.isNotEmpty() && path != "/") return null

        val rawQuery = parsed.rawQuery ?: return null
        val encodedCode = rawQuery
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

        val decodedCode = runCatching {
            URLDecoder.decode(
                encodedCode,
                StandardCharsets.UTF_8.name()
            )
        }.getOrNull() ?: return null

        val allowedCode = Regex(
            "^\\d{12}$|^\\d{4}[ -]\\d{4}[ -]\\d{4}$"
        )
        if (!allowedCode.matches(decodedCode)) return null

        return PairingCode.normalize(decodedCode)
    }
}

object PairingShareText {
    fun build(code: String): String {
        val normalized = PairingCode.normalize(code)
            ?: error("Pairing code must contain " + PairingCode.DIGITS + " digits")

        return "Aaris Remote code: ${PairingCode.display(normalized)}\n" +
            "Tap to join: ${PairingLink.uri(normalized)}\n" +
            "Or open Aaris Remote → Connect → START."
    }
}
