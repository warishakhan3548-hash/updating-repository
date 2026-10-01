package com.aaris.remoteassist.webrtc

import java.util.ArrayDeque

internal class CandidatePublishGate<T>(
    private val capacity: Int
) {
    private val lock = Any()
    private val pending = ArrayDeque<T>()

    private var epoch = 0L
    private var descriptionPublished = false

    init {
        require(capacity > 0)
    }

    fun beginNegotiation(): Long = synchronized(lock) {
        epoch += 1L
        descriptionPublished = false
        pending.clear()
        epoch
    }

    fun currentEpoch(): Long = synchronized(lock) {
        epoch
    }

    fun offer(item: T): T? = synchronized(lock) {
        if (descriptionPublished) {
            item
        } else {
            if (pending.size >= capacity) {
                pending.removeFirst()
            }
            pending.addLast(item)
            null
        }
    }

    fun markDescriptionPublished(
        expectedEpoch: Long
    ): List<T> = synchronized(lock) {
        if (expectedEpoch != epoch) {
            return@synchronized emptyList()
        }

        descriptionPublished = true
        buildList(pending.size) {
            while (pending.isNotEmpty()) {
                add(pending.removeFirst())
            }
        }
    }

    fun reset() = synchronized(lock) {
        descriptionPublished = false
        pending.clear()
    }
}
