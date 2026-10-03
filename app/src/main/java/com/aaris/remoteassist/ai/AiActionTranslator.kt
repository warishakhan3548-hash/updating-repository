package com.aaris.remoteassist.ai

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlPathPoint
import com.aaris.remoteassist.control.ControlProtocol
import com.aaris.remoteassist.control.RemoteCommand
import com.aaris.remoteassist.session.LiveLease
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

        val secret = lease.leaseSecret
        val generation = lease.displayGeneration
        val duration = args.optInt("durationMs", 350).also { require(it in 80..1500) }
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
            "swipe" -> ControlPacket.Swipe(secret, generation, sequence, unit("x"), unit("y"), unit("toX"), unit("toY"), duration)
            "drag" -> ControlPacket.GesturePath(secret, generation, sequence, dragPoints(), duration)
            "two_finger" -> ControlPacket.TwoFinger(
                secret,
                generation,
                sequence,
                unit("firstX"),
                unit("firstY"),
                unit("firstToX"),
                unit("firstToY"),
                unit("secondX"),
                unit("secondY"),
                unit("secondToX"),
                unit("secondToY"),
                duration
            )
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
