package com.aaris.shield.network

import java.net.IDN
import java.util.Locale

enum class DomainDecision {
    ALLOW,
    BLOCK,
}

class DomainPolicy private constructor(
    private val blockedDomains: Set<String>,
    private val allowedDomains: Set<String>,
) {
    val blockedRuleCount: Int get() = blockedDomains.size
    val allowedRuleCount: Int get() = allowedDomains.size

    fun decide(domain: String): DomainDecision {
        val normalized = normalizeDomain(domain) ?: return DomainDecision.ALLOW
        if (matchesSuffix(normalized, allowedDomains)) return DomainDecision.ALLOW
        return if (matchesSuffix(normalized, blockedDomains)) DomainDecision.BLOCK else DomainDecision.ALLOW
    }

    companion object {
        fun fromLines(blocked: Sequence<String>, allowed: Sequence<String>): DomainPolicy {
            val blockedRules = blocked.mapNotNull(::parseRule).toSet()
            val allowedRules = allowed.mapNotNull(::parseRule).toSet()
            return DomainPolicy(blockedRules, allowedRules)
        }

        internal fun normalizeDomain(value: String): String? {
            val trimmed = value.trim().trimEnd('.')
            if (trimmed.isEmpty()) return null
            val ascii = try {
                IDN.toASCII(trimmed, IDN.USE_STD3_ASCII_RULES)
            } catch (_: IllegalArgumentException) {
                return null
            }.lowercase(Locale.ROOT)
            if (ascii.length !in 1..253) return null
            if (ascii.split('.').any { it.isEmpty() || it.length > 63 }) return null
            return ascii
        }

        private fun parseRule(rawLine: String): String? {
            val withoutComment = rawLine.substringBefore('#').trim()
            if (withoutComment.isEmpty()) return null
            val hostToken = withoutComment
                .split(Regex("""\s+"""))
                .last()
                .removePrefix("||")
                .removeSuffix("^")
                .removePrefix("*.")
            return normalizeDomain(hostToken)
        }

        private fun matchesSuffix(domain: String, rules: Set<String>): Boolean {
            var candidate = domain
            while (true) {
                if (candidate in rules) return true
                val dot = candidate.indexOf('.')
                if (dot < 0) return false
                candidate = candidate.substring(dot + 1)
            }
        }
    }
}
