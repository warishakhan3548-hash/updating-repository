package com.aaris.shield.network

import android.content.Context

internal object OfflineDomainPolicyLoader {
    private const val BLOCKED_ASSET = "aaris_shield/adult_domains.txt"
    private const val ALLOWED_ASSET = "aaris_shield/allow_domains.txt"

    fun load(context: Context): DomainPolicy {
        val blocked = readLines(context, BLOCKED_ASSET)
        val allowed = readLines(context, ALLOWED_ASSET)
        return DomainPolicy.fromLines(blocked.asSequence(), allowed.asSequence()).also { policy ->
            check(policy.blockedRuleCount > 0) { "Adult-domain blocklist is empty" }
        }
    }

    private fun readLines(context: Context, path: String): List<String> =
        context.assets.open(path).bufferedReader(Charsets.UTF_8).use { it.readLines() }
}
