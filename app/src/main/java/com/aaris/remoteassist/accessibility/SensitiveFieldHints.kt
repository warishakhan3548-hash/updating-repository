package com.aaris.remoteassist.accessibility

internal object SensitiveFieldHints {
    private val camelBoundary =
        Regex("(?<=[a-z0-9])(?=[A-Z])")
    private val separators =
        Regex("[^A-Za-z0-9]+")

    private val strongTerms = listOf(
        "password",
        "passwd",
        "pwd",
        "otp",
        "one time",
        "verification code",
        "verify code",
        "passcode",
        "cvv",
        "cvc",
        "security code",
        "2fa",
        "mfa",
        "auth code",
        "authentication code"
    )

    private val securityPinTerms = listOf(
        "mpin",
        "upi pin",
        "atm pin",
        "login pin",
        "security pin",
        "transaction pin",
        "payment pin",
        "pass pin"
    )

    fun isSensitive(metadata: String): Boolean {
        if (metadata.isBlank()) return false

        val normalized = camelBoundary
            .replace(metadata, " ")
            .replace(separators, " ")
            .lowercase()
            .trim()
            .replace(Regex("\\s+"), " ")

        val compact = normalized.replace(" ", "")

        if (strongTerms.any { term ->
                normalized.contains(term) ||
                    compact.contains(term.replace(" ", ""))
            }
        ) {
            return true
        }

        if (securityPinTerms.any { term ->
                normalized.contains(term) ||
                    compact.contains(term.replace(" ", ""))
            }
        ) {
            return true
        }

        val hasStandalonePin =
            Regex("\\bpin\\b").containsMatchIn(normalized)
        val looksPostal = listOf(
            "postal",
            "shipping",
            "address",
            "zip",
            "pin code"
        ).any(normalized::contains)

        return hasStandalonePin && !looksPostal
    }
}
