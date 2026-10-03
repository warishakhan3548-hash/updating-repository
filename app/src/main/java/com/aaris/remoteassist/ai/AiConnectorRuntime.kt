package com.aaris.remoteassist.ai

import java.util.concurrent.CopyOnWriteArraySet

data class AiConnectorState(val active: Boolean = false, val online: Boolean = false, val message: String = "AI control is off")

object AiConnectorRuntime {
    @Volatile var state = AiConnectorState()
        private set
    private val listeners = CopyOnWriteArraySet<(AiConnectorState) -> Unit>()
    fun update(value: AiConnectorState) {
        if (state == value) return
        state = value
        listeners.forEach { runCatching { it(value) } }
    }
    fun addListener(listener: (AiConnectorState) -> Unit) { listeners += listener; listener(state) }
    fun removeListener(listener: (AiConnectorState) -> Unit) { listeners -= listener }
}
