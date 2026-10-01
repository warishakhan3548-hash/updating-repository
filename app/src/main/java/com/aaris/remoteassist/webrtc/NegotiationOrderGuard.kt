package com.aaris.remoteassist.webrtc

import java.util.ArrayDeque

internal class NegotiationOrderGuard(
    private val retiredCapacity: Int = 8
) {
    private val lock = Any()
    private var remoteClientId: String? = null
    private var highestEpoch = 0L
    private val retiredClientIds = ArrayDeque<String>()

    init {
        require(retiredCapacity > 0)
    }

    fun accept(
        negotiationId: String,
        allowCurrentDuplicate: Boolean = false
    ): Boolean = synchronized(lock) {
            if (negotiationId == LEGACY_NEGOTIATION_ID) {
                return@synchronized remoteClientId == null
            }

            val parsed = parse(negotiationId)
                ?: return@synchronized false
            val (clientId, epoch) = parsed
            val activeClient = remoteClientId

            if (activeClient == null) {
                remoteClientId = clientId
                highestEpoch = epoch
                return@synchronized true
            }

            if (activeClient != clientId) {
                if (retiredClientIds.contains(clientId)) {
                    return@synchronized false
                }

                retire(activeClient)
                remoteClientId = clientId
                highestEpoch = epoch
                return@synchronized true
            }

            if (epoch < highestEpoch) {
                return@synchronized false
            }

            if (epoch == highestEpoch) {
                return@synchronized allowCurrentDuplicate
            }

            highestEpoch = epoch
            true
        }

    private fun retire(clientId: String) {
        if (retiredClientIds.contains(clientId)) return

        if (retiredClientIds.size >= retiredCapacity) {
            retiredClientIds.removeFirst()
        }
        retiredClientIds.addLast(clientId)
    }

    private fun parse(
        negotiationId: String
    ): Pair<String, Long>? {
        if (negotiationId.isBlank()) {
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
        if (clientId.length > MAX_CLIENT_ID_CHARS) {
            return null
        }

        val epoch = negotiationId
            .substring(separator + 1)
            .toLongOrNull()
            ?: return null

        if (epoch <= 0L) return null
        return clientId to epoch
    }

    companion object {
        private const val MAX_CLIENT_ID_CHARS = 64
    }
}
