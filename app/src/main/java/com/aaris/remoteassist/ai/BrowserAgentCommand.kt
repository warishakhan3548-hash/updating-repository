package com.aaris.remoteassist.ai

import android.util.JsonReader
import android.util.JsonToken
import java.io.StringReader
import org.json.JSONObject

/** Complete, session-scoped commands; prose, templates and streamed fragments are not commands. */
object BrowserAgentCommand {
    const val BEGIN = "AARIS_ACTION_BEGIN"
    const val END = "AARIS_ACTION_END"
    val chatPackages = setOf("com.openai.chatgpt", "com.anthropic.claude", "com.microsoft.copilot", "ai.perplexity.app.android")
    private val common = setOf("protocol", "nonce", "actionId", "observationId", "screenVersion", "action")

    /** A browser action and a same-phone chat reply use the same held target. */
    fun requiresTargetResume(action: String, foregroundPackage: String?): Boolean =
        action !in setOf("home", "open_app") && foregroundPackage in chatPackages

    fun parse(text: String, nonce: String, assistantMessage: Boolean): JSONObject? = runCatching {
        require(assistantMessage && text.length <= 16384)
        val begin = text.indexOf(BEGIN)
        val end = text.indexOf(END)
        require(begin >= 0 && end > begin && text.indexOf(BEGIN, begin + 1) < 0 && text.indexOf(END, end + 1) < 0)
        val json = text.substring(begin + BEGIN.length, end).trim().removePrefix("```json").removePrefix("```").removeSuffix("```").trim()
        validateJson(json)
        validate(JSONObject(json), nonce)
    }.getOrNull()

    fun validate(value: JSONObject, nonce: String): JSONObject {
        require(value.getString("protocol") == "aaris-link-v1" && value.getString("nonce") == nonce)
        require(value.getString("actionId").matches(Regex("[a-zA-Z0-9_-]{8,80}")))
        require(value.getString("observationId").matches(Regex("[a-f0-9-]{36}")))
        require(value.get("screenVersion") is Number && value.getDouble("screenVersion") == value.getLong("screenVersion").toDouble() && value.getLong("screenVersion") > 0)
        val action = value.getString("action")
        val fields = when (action) {
            "tap" -> setOf("x", "y")
            "long_press" -> setOf("x", "y", "durationMs")
            "swipe" -> setOf("x", "y", "toX", "toY", "durationMs")
            "drag" -> setOf("points", "durationMs")
            "type" -> setOf("text")
            "open_app" -> setOf("app")
            "back", "home", "recents" -> emptySet()
            else -> error("UNSUPPORTED_ACTION")
        }
        require(value.keys().asSequence().all { it in common || it in fields })
        for (key in listOf("x", "y", "toX", "toY")) if (key in fields) {
            require(value.get(key) is Number && value.getDouble(key).isFinite() && value.getDouble(key) in 0.0..1.0)
        }
        if (value.has("durationMs")) require(value.get("durationMs") is Number && value.getDouble("durationMs") == value.getInt("durationMs").toDouble() && value.getInt("durationMs") in 80..1500)
        if (action == "drag") {
            val points = value.getJSONArray("points"); require(points.length() in 2..24)
            repeat(points.length()) { i ->
                val p = points.getJSONObject(i); require(p.length() == 2)
                for (k in listOf("x", "y")) require(p.get(k) is Number && p.getDouble(k).isFinite() && p.getDouble(k) in 0.0..1.0)
            }
        }
        if (action == "type") require(value.getString("text").isNotEmpty() && value.getString("text").length <= 1000 && value.getString("text").toByteArray().size <= 2048)
        if (action == "open_app") require(value.getString("app").isNotBlank() && value.getString("app").length <= 160)
        return value
    }

    // JSONObject tolerates duplicate keys on Android. Reject ambiguous JSON first.
    private fun validateJson(text: String) {
        JsonReader(StringReader(text)).use { reader ->
            reader.isLenient = false
            fun consume(depth: Int) {
                require(depth <= 8)
                when (reader.peek()) {
                    JsonToken.BEGIN_OBJECT -> {
                        reader.beginObject(); val names = mutableSetOf<String>()
                        while (reader.hasNext()) { require(names.add(reader.nextName())); consume(depth + 1) }
                        reader.endObject()
                    }
                    JsonToken.BEGIN_ARRAY -> { reader.beginArray(); while (reader.hasNext()) consume(depth + 1); reader.endArray() }
                    JsonToken.STRING, JsonToken.NUMBER -> reader.nextString()
                    JsonToken.BOOLEAN -> reader.nextBoolean()
                    JsonToken.NULL -> reader.nextNull()
                    else -> error("INVALID_JSON")
                }
            }
            require(reader.peek() == JsonToken.BEGIN_OBJECT); consume(0); require(reader.peek() == JsonToken.END_DOCUMENT)
        }
    }
}
