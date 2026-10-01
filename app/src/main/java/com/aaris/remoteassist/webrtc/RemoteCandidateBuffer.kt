package com.aaris.remoteassist.webrtc

import java.util.ArrayDeque

internal class RemoteCandidateBuffer<T>(
    private val capacity: Int
) {
    private data class Entry<T>(
        val negotiationId: String,
        val value: T
    )

    private val lock = Any()
    private val pending = ArrayDeque<Entry<T>>()

    private var activeNegotiationId: String? = null
    private var descriptionReady = false

    init {
        require(capacity > 0)
    }

    fun beginRemoteDescription(
        negotiationId: String
    ) = synchronized(lock) {
        activeNegotiationId = negotiationId
        descriptionReady = false

        val retained = pending
            .filter { it.negotiationId == negotiationId }

        pending.clear()
        retained
            .takeLast(capacity)
            .forEach(pending::addLast)
    }

    fun markDescriptionReady(): List<T> =
        synchronized(lock) {
            descriptionReady = true
            drainActiveLocked()
        }

    fun markDescriptionNotReady() = synchronized(lock) {
        descriptionReady = false
    }

    fun offer(
        negotiationId: String,
        value: T
    ): T? = synchronized(lock) {
        if (
            descriptionReady &&
            activeNegotiationId == negotiationId
        ) {
            return@synchronized value
        }

        if (pending.size >= capacity) {
            pending.removeFirst()
        }
        pending.addLast(
            Entry(
                negotiationId = negotiationId,
                value = value
            )
        )
        null
    }

    fun reset() = synchronized(lock) {
        activeNegotiationId = null
        descriptionReady = false
        pending.clear()
    }

    private fun drainActiveLocked(): List<T> {
        val activeId = activeNegotiationId
            ?: return emptyList()

        val ready = mutableListOf<T>()
        val retained = mutableListOf<Entry<T>>()

        while (pending.isNotEmpty()) {
            val entry = pending.removeFirst()
            if (entry.negotiationId == activeId) {
                ready += entry.value
            } else {
                retained += entry
            }
        }

        retained
            .takeLast(capacity)
            .forEach(pending::addLast)

        return ready
    }
}
