package com.aaris.remoteassist.ai

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlPathPoint
import com.aaris.remoteassist.control.ControlProtocol
import com.aaris.remoteassist.control.RemoteCommand
import com.aaris.remoteassist.session.LiveLease
import kotlin.math.hypot
import kotlin.math.roundToInt
import org.json.JSONObject

object AiActionTranslator {
    private const val MAX_AI_DRAG_POINTS = 24

    fun translate(args: JSONObject, lease: LiveLease, sequence: Long, width: Int, height: Int): RemoteCommand {
        fun unit(value: Any): Float {
            require(value is Number)
            val normalized = value.toDouble()
            require(normalized.isFinite() && normalized in 0.0..1.0)
            return normalized.toFloat()
        }
        fun unit(key: String): Float = unit(args.get(key))
        fun dragPoints(): List<ControlPathPoint> {
            val raw = args.getJSONArray("points")
            require(raw.length() in 2..MAX_AI_DRAG_POINTS)
            return List(raw.length()) { index ->
                val point = raw.getJSONObject(index)
                require(point.length() == 2 && point.has("x") && point.has("y"))
                ControlPathPoint(unit(point.get("x")), unit(point.get("y")))
            }
        }
        fun boundedDuration(defaultMs: Int): Int =
            args.optInt("durationMs", defaultMs).also { require(it in 80..1500) }

        /*
         * Different gestures need different default motor profiles. A navigation
         * swipe/flick should get out of the way quickly, while a path drag needs
         * enough dwell time for small controls and continued Android strokes to
         * track the requested curve. The AI can still override durationMs when
         * the task explicitly calls for a very fast or very slow motion.
         */
        fun adaptiveSwipeDuration(distance: Double): Int =
            (110.0 + distance.coerceIn(0.0, 1.25) * 180.0)
                .roundToInt()
                .coerceIn(110, 335)
        fun adaptiveDragDuration(distance: Double): Int =
            (160.0 + distance.coerceIn(0.0, 1.25) * 270.0)
                .roundToInt()
                .coerceIn(160, 500)
        fun adaptiveTwoFingerDuration(distance: Double): Int =
            (150.0 + distance.coerceIn(0.0, 1.25) * 240.0)
                .roundToInt()
                .coerceIn(150, 450)
        fun pathDistance(points: List<ControlPathPoint>): Double =
            points.zipWithNext().sumOf { (from, to) ->
                hypot(
                    (to.nx - from.nx).toDouble(), (to.ny - from.ny).toDouble()
                )
            }

        val secret = lease.leaseSecret
        val generation = lease.displayGeneration
        val packet = when (args.getString("action")) {
            "tap" -> ControlPacket.Tap(secret, generation, sequence, unit("x"), unit("y"))
            "long_press" -> ControlPacket.LongPress(
                secret,
                generation,
                sequence,
                unit("x"),
                unit("y"),
                args.optInt("durationMs", 650).coerceIn(450, 1500)
            )
            "swipe" -> {
                val x = unit("x")
                val y = unit("y")
                val toX = unit("toX")
                val toY = unit("toY")
                val distance = hypot((toX - x).toDouble(), (toY - y).toDouble())
                ControlPacket.Swipe(
                    secret,
                    generation,
                    sequence,
                    x,
                    y,
                    toX,
                    toY,
                    boundedDuration(adaptiveSwipeDuration(distance))
                )
            }
            "drag" -> {
                val points = dragPoints()
                ControlPacket.GesturePath(
                    secret,
                    generation,
                    sequence,
                    points,
                    boundedDuration(adaptiveDragDuration(pathDistance(points)))
                )
            }
            "two_finger" -> {
                val x = unit("x")
                val y = unit("y")
                val toX = unit("toX")
                val toY = unit("toY")
                val secondX = unit("secondX")
                val secondY = unit("secondY")
                val secondToX = unit("secondToX")
                val secondToY = unit("secondToY")
                val firstDistance = hypot((toX - x).toDouble(), (toY - y).toDouble())
                val secondDistance = hypot(
                    (secondToX - secondX).toDouble(), (secondToY - secondY).toDouble()
                )
                ControlPacket.TwoFinger(
                    leaseSecret = secret,
                    generation = generation,
                    sequence = sequence,
                    firstFromNx = x,
                    firstFromNy = y,
                    firstToNx = toX,
                    firstToNy = toY,
                    secondFromNx = secondX,
                    secondFromNy = secondY,
                    secondToNx = secondToX,
                    secondToNy = secondToY,
                    durationMs = boundedDuration(adaptiveTwoFingerDuration(maxOf(firstDistance, secondDistance)))
                )
            }
            "back" -> ControlPacket.Back(secret, generation, sequence)
            "home" -> ControlPacket.Home(secret, generation, sequence)
            "recents" -> ControlPacket.Recents(secret, generation, sequence)
            "type" -> {
                val text = args.getString("text")
                require(text.isNotEmpty() && text.length <= 1000 && text.toByteArray(Charsets.UTF_8).size <= 2048)
                ControlPacket.Text(secret, generation, sequence, text)
            }
            else -> error("UNSUPPORTED_ACTION")
        }
        // Reuse the human controller's protocol and pixel mapping. AI receives
        // extra planning primitives, not a second privileged execution path.
        return checkNotNull(
            ControlProtocol.toRemoteCommand(
                sessionId = lease.sessionId,
                packet = packet,
                widthPx = width,
                heightPx = height
            )
        )
    }
}
