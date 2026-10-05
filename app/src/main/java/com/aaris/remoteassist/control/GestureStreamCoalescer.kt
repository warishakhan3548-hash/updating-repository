package com.aaris.remoteassist.control

/**
 * Preserves the geometric path of freshness-coalesced live gestures.
 *
 * The transport and Accessibility queue intentionally discard stale CONTINUE
 * work under pressure. Dropping a queued segment must not also discard the
 * curve it carried, otherwise the next continuation can shortcut directly from
 * Android's last applied endpoint to a much newer point. Merge the superseded
 * path into the newest segment, then deterministically resample to the existing
 * protocol bound so latency and packet size stay bounded.
 */
internal object GestureStreamCoalescer {
    private const val DEFAULT_MAX_POINTS = 16
    private const val MIN_DURATION_MS = 12L
    private const val DEFAULT_MAX_DURATION_MS = 120L

    fun merge(
        superseded: List<GestureStreamCommand>,
        incoming: GestureStreamCommand,
        maxPoints: Int = DEFAULT_MAX_POINTS,
        maxDurationMs: Long = DEFAULT_MAX_DURATION_MS
    ): GestureStreamCommand {
        require(maxPoints >= 1)
        require(maxDurationMs >= MIN_DURATION_MS)

        if (
            superseded.isEmpty() ||
            incoming.phase == GestureStreamPhase.START
        ) {
            return incoming
        }

        val compatible = superseded.filter { previous ->
            previous.phase == GestureStreamPhase.CONTINUE &&
                previous.streamId == incoming.streamId &&
                previous.sessionId == incoming.sessionId &&
                previous.leaseSecret == incoming.leaseSecret &&
                previous.generation == incoming.generation
        }
        if (compatible.isEmpty()) return incoming

        val merged = ArrayList<RemotePathPoint>()
        fun append(points: List<RemotePathPoint>) {
            points.forEach { point ->
                if (merged.lastOrNull() != point) {
                    merged += point
                }
            }
        }

        compatible.forEach { append(it.points) }
        append(incoming.points)

        val bounded = resample(merged, maxPoints)

        var totalDuration = incoming.durationMs.coerceAtLeast(0L)
        compatible.forEach { previous ->
            val delta = previous.durationMs.coerceAtLeast(0L)
            totalDuration =
                if (totalDuration > Long.MAX_VALUE - delta) {
                    Long.MAX_VALUE
                } else {
                    totalDuration + delta
                }
        }

        return incoming.copy(
            points = bounded.ifEmpty { incoming.points },
            durationMs =
                totalDuration.coerceIn(
                    MIN_DURATION_MS,
                    maxDurationMs
                )
        )
    }

    private fun resample(
        points: List<RemotePathPoint>,
        maxPoints: Int
    ): List<RemotePathPoint> {
        if (points.size <= maxPoints) return points.toList()
        if (maxPoints == 1) return listOf(points.last())

        val last = points.lastIndex
        return List(maxPoints) { sample ->
            val index =
                (
                    sample.toLong() *
                        last.toLong() /
                        (maxPoints - 1).toLong()
                    ).toInt()
            points[index]
        }
    }
}
