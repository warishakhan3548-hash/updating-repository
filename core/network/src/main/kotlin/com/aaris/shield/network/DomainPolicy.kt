package com.aaris.shield.network

import java.net.IDN
import java.util.Locale

enum class DomainDecision {
    ALLOW,
    BLOCK,
}

/**
 * Exact/suffix domain policy with a most-specific-rule-wins contract.
 *
 * A rule for example.com also applies to sub.example.com. A more specific
 * allow rule can safely carve out a child of a blocked parent, while a more
 * specific block rule still wins beneath a broader allow rule. Ties favor the
 * allowlist so an explicit exception can override the corresponding block.
 */
class DomainPolicy(
    blockedDomains: Iterable<String>,
    allowedDomains: Iterable<String> = emptyList(),
) {
    private val blocked = normalizeRules(blockedDomains)
    private val allowed = normalizeRules(allowedDomains)

    fun decide(domain: String): DomainDecision {
        val normalized = DomainNames.normalize(domain) ?: return DomainDecision.ALLOW
        val blockSpecificity = matchSpecificity(normalized, blocked)
        val allowSpecificity = matchSpecificity(normalized, allowed)

        return when {
            blockSpecificity < 0 -> DomainDecision.ALLOW
            allowSpecificity >= blockSpecificity -> DomainDecision.ALLOW
            else -> DomainDecision.BLOCK
        }
    }

    fun isBlocked(domain: String): Boolean = decide(domain) == DomainDecision.BLOCK

    companion object {
        fun parseRuleLines(lines: Sequence<String>): Set<String> = lines
            .map(String::trim)
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .map { line ->
                val withoutInlineComment = line.substringBefore('#').trim()
                val token = withoutInlineComment.split(Regex("\\s+")).lastOrNull().orEmpty()
                token.removePrefix("*.")
            }
            .mapNotNull(DomainNames::normalize)
            .toSet()

        private fun normalizeRules(rules: Iterable<String>): Set<String> = rules
            .mapNotNull(DomainNames::normalize)
            .toSet()

        private fun matchSpecificity(domain: String, rules: Set<String>): Int {
            var candidate = domain
            while (true) {
                if (candidate in rules) return candidate.length
                val dot = candidate.indexOf('.')
                if (dot < 0) return -1
                candidate = candidate.substring(dot + 1)
            }
        }
    }
}

object DomainNames {
    fun normalize(value: String): String? {
        val trimmed = value.trim().trimEnd('.')
        if (trimmed.isEmpty() || trimmed.length > 253) return null

        val ascii = try {
            IDN.toASCII(trimmed, IDN.USE_STD3_ASCII_RULES)
        } catch (_: IllegalArgumentException) {
            return null
        }.lowercase(Locale.ROOT)

        if (ascii.isEmpty() || ascii.length > 253) return null
        val labels = ascii.split('.')
        if (labels.any { it.isEmpty() || it.length > 63 }) return null
        return ascii
    }
}
