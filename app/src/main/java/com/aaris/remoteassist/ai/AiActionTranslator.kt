package com.aaris.remoteassist.ai

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import com.aaris.remoteassist.control.RemoteCommand
import com.aaris.remoteassist.session.LiveLease
import org.json.JSONObject

object AiActionTranslator {
    fun translate(args: JSONObject, lease: LiveLease, sequence: Long, width: Int, height: Int): RemoteCommand {
        fun unit(key: String): Float {
            val raw = args.get(key)
            require(raw is Number)
            val value = raw.toDouble()
            require(value.isFinite() && value in 0.0..1.0)
            return value.toFloat()
        }
        val secret = lease.leaseSecret; val generation = lease.displayGeneration
        val duration = args.optInt("durationMs", 350).also { require(it in 80..1500) }
        val packet = when (args.getString("action")) {
            "tap" -> ControlPacket.Tap(secret, generation, sequence, unit("x"), unit("y"))
            "long_press" -> ControlPacket.LongPress(secret, generation, sequence, unit("x"), unit("y"), args.optInt("durationMs", 650).coerceAtLeast(450))
            "swipe" -> ControlPacket.Swipe(secret, generation, sequence, unit("x"), unit("y"), unit("toX"), unit("toY"), duration)
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
        // Uses exactly the same pixel mapping as the human controller.
        return checkNotNull(ControlProtocol.toRemoteCommand(sessionId = lease.sessionId, packet = packet, widthPx = width, heightPx = height))
    }
}
