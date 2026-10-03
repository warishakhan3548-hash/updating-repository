package com.aaris.remoteassist.ai

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlPathPoint
import com.aaris.remoteassist.control.ControlProtocol
import com.aaris.remoteassist.control.RemoteCommand
import org.json.JSONObject

object AiActionTranslator {
    fun translate(
        sessionId: String,
        leaseSecret: Long,
        generation: Int,
        sequence: Long,
        widthPx: Int,
        heightPx: Int,
        args: JSONObject
    ): RemoteCommand? {
        val action = args.getString("action")
        val packet = when (action) {
            "tap" -> ControlPacket.Tap(
                leaseSecret,
                generation,
                sequence,
                unit(args, "x"),
                unit(args, "y")
            )
            "long_press" -> ControlPacket.LongPress(
                leaseSecret,
                generation,
                sequence,
                unit(args, "x"),
                unit(args, "y"),
                duration(args)
            )
            "swipe" -> ControlPacket.Swipe(
                leaseSecret,
                generation,
                sequence,
                unit(args, "x"),
                unit(args, "y"),
                unit(args, "toX"),
                unit(args, "toY"),
                duration(args)
            )
            "gesture_path" -> ControlPacket.GesturePath(
                leaseSecret = leaseSecret,
                generation = generation,
                sequence = sequence,
                points = gesturePoints(args),
                durationMs = duration(args)
            )
            "two_finger" -> ControlPacket.TwoFinger(
                leaseSecret = leaseSecret,
                generation = generation,
                sequence = sequence,
                firstFromNx = unit(args, "firstX"),
                firstFromNy = unit(args, "firstY"),
                firstToNx = unit(args, "firstToX"),
                firstToNy = unit(args, "firstToY"),
                secondFromNx = unit(args, "secondX"),
                secondFromNy = unit(args, "secondY"),
                secondToNx = unit(args, "secondToX"),
                secondToNy = unit(args, "secondToY"),
                durationMs = duration(args)
            )
            "back" -> ControlPacket.Back(leaseSecret, generation, sequence)
            "home" -> ControlPacket.Home(leaseSecret, generation, sequence)
            "recents" -> ControlPacket.Recents(leaseSecret, generation, sequence)
            "type" -> ControlPacket.Text(leaseSecret, generation, sequence, args.getString("text"))
            else -> return null
        }
        return ControlProtocol.toRemoteCommand(sessionId, packet, widthPx, heightPx)
    }

    private fun unit(args: JSONObject, key: String): Float {
        val value = args.getDouble(key)
        require(value.isFinite() && value in 0.0..1.0) { "Invalid normalized coordinate: $key" }
        return value.toFloat()
    }

    private fun duration(args: JSONObject): Int =
        args.optInt("durationMs", DEFAULT_GESTURE_MS).coerceIn(MIN_GESTURE_MS, MAX_GESTURE_MS)

    private fun gesturePoints(args: JSONObject): List<ControlPathPoint> {
        val source = args.getJSONArray("points")
        require(source.length() in MIN_GESTURE_POINTS..MAX_AI_GESTURE_POINTS) {
            "AI gesture path must contain $MIN_GESTURE_POINTS..$MAX_AI_GESTURE_POINTS points"
        }
        return buildList(source.length()) {
            for (index in 0 until source.length()) {
                val point = source.getJSONObject(index)
                add(ControlPathPoint(unit(point, "x"), unit(point, "y")))
            }
        }
    }

    private const val DEFAULT_GESTURE_MS = 180
    private const val MIN_GESTURE_MS = 80
    private const val MAX_GESTURE_MS = 1_500
    private const val MIN_GESTURE_POINTS = 2
    private const val MAX_AI_GESTURE_POINTS = 32
}
