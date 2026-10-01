package com.aaris.remoteassist.webrtc

internal class NegotiationOrderGuard {
    private val lock = Any()
    private var remoteClientId: String? = null
    private var highestEpoch = 0L

    fun accept(negotiationId: String): Boolean =
        synchronized(lock) {
            val parsed = parse(negotiationId)

            if (parsed == null) {
                return@synchronized remoteClientId == null
            }

            val (clientId, epoch) = parsed
            if (remoteClientId != clientId) {
                remoteClientId = clientId
                highestEpoch = epoch
                return@synchronized true
            }

            if (epoch <= highestEpoch) {
                return@synchronized false
            }

            highestEpoch = epoch
            true
        }

    private fun parse(
        negotiationId: String
    ): Pair<String, Long>? {
        if (
            negotiationId.isBlank() ||
            negotiationId == LEGACY_NEGOTIATION_ID
        ) {
            return null
        }

        val separator = negotiationId.lastIndexOf(':')
        if (
            separator <= 0 ||
            separator >= negotiationId.lastIndex
        ) {
            return null
        }

        val clientId = negotiationId.substring(0, separator)
        val epoch = negotiationId
            .substring(separator + 1)
            .toLongOrNull()
            ?: return null

        if (epoch <= 0L) return null
        return clientId to epoch
    }
}
