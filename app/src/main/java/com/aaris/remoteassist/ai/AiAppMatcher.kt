package com.aaris.remoteassist.ai

data class AiLaunchCandidate(
    val label: String,
    val packageName: String,
    val activityName: String
)

/** Conservative matching: fast when unambiguous, never fuzzy-click the wrong app. */
object AiAppMatcher {
    fun choose(query: String, candidates: List<AiLaunchCandidate>): AiLaunchCandidate? {
        val raw = query.trim()
        if (raw.isEmpty() || raw.length > 160) return null
        val normalized = normalize(raw)
        if (normalized.isEmpty()) return null
        val queryTokens = normalized.split(' ').filter(String::isNotBlank).toSet()

        val scored = candidates.mapNotNull { candidate ->
            val label = normalize(candidate.label)
            val packageTail = normalize(candidate.packageName.substringAfterLast('.'))
            val score = when {
                candidate.packageName.equals(raw, ignoreCase = true) -> 120
                label == normalized -> 110
                packageTail == normalized -> 100
                label.startsWith("$normalized ") || label.endsWith(" $normalized") -> 90
                queryTokens.size >= 2 && queryTokens.all { it in label.split(' ') } -> 80
                else -> 0
            }
            score.takeIf { it > 0 }?.let { score to candidate }
        }.sortedByDescending { it.first }

        val best = scored.firstOrNull() ?: return null
        val tied = scored.filter { it.first == best.first }
        return when {
            tied.size == 1 -> best.second
            tied.map { it.second.packageName }.distinct().size == 1 -> tied.first().second
            else -> null
        }
    }

    private fun normalize(value: String): String =
        value.lowercase()
            .map { if (it.isLetterOrDigit()) it else ' ' }
            .joinToString("")
            .trim()
            .replace(Regex("\\s+"), " ")
}
