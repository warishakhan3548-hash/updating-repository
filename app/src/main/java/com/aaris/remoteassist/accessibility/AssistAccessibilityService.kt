package com.aaris.remoteassist.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent
import com.aaris.remoteassist.control.CommandGate
import com.aaris.remoteassist.control.GlobalAction
import com.aaris.remoteassist.control.GlobalActionCommand
import com.aaris.remoteassist.control.LongPressCommand
import com.aaris.remoteassist.control.RemoteCommand
import com.aaris.remoteassist.control.SwipeCommand
import com.aaris.remoteassist.control.TapCommand
import java.lang.ref.WeakReference

class AssistAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        instance = WeakReference(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    override fun onDestroy() {
        instance.clear()
        super.onDestroy()
    }

    private fun execute(command: RemoteCommand): Boolean {
        if (!CommandGate.accept(command)) return false
        return when (command) {
            is TapCommand -> gesture(command.xPx, command.yPx, command.xPx, command.yPx, 55L)
            is LongPressCommand -> gesture(
                command.xPx,
                command.yPx,
                command.xPx,
                command.yPx,
                command.durationMs.coerceIn(450L, 1500L)
            )
            is SwipeCommand -> gesture(
                command.fromXPx,
                command.fromYPx,
                command.toXPx,
                command.toYPx,
                command.durationMs.coerceIn(80L, 1500L)
            )
            is GlobalActionCommand -> performGlobalAction(
                when (command.action) {
                    GlobalAction.BACK -> GLOBAL_ACTION_BACK
                    GlobalAction.HOME -> GLOBAL_ACTION_HOME
                }
            )
        }
    }

    private fun gesture(
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long
    ): Boolean {
        if (!fromX.isFinite() || !fromY.isFinite() || !toX.isFinite() || !toY.isFinite()) {
            return false
        }
        val path = Path().apply {
            moveTo(fromX, fromY)
            if (fromX != toX || fromY != toY) lineTo(toX, toY)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0L, durationMs)
        return dispatchGesture(
            GestureDescription.Builder().addStroke(stroke).build(),
            null,
            null
        )
    }

    companion object {
        private var instance = WeakReference<AssistAccessibilityService>(null)

        fun dispatch(command: RemoteCommand): Boolean =
            instance.get()?.execute(command) ?: false

        fun isConnected(): Boolean = instance.get() != null
    }
}
