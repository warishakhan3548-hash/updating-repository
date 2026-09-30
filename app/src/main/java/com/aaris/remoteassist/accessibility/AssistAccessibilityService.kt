package com.aaris.remoteassist.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.Button
import com.aaris.remoteassist.capture.ScreenShareService
import com.aaris.remoteassist.control.CommandGate
import com.aaris.remoteassist.control.GlobalAction
import com.aaris.remoteassist.control.GlobalActionCommand
import com.aaris.remoteassist.control.LongPressCommand
import com.aaris.remoteassist.control.RemoteCommand
import com.aaris.remoteassist.control.SwipeCommand
import com.aaris.remoteassist.control.TapCommand
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionSnapshot
import com.aaris.remoteassist.session.SessionState
import java.lang.ref.WeakReference

class AssistAccessibilityService : AccessibilityService() {
    private var stopOverlay: View? = null

    private val sessionListener: (SessionSnapshot) -> Unit = { snapshot ->
        mainExecutor.execute {
            if (snapshot.state == SessionState.LIVE) {
                showStopOverlay()
            } else {
                hideStopOverlay()
            }
        }
    }

    override fun onServiceConnected() {
        instance = WeakReference(this)
        SessionCoordinator.addListener(sessionListener)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        SessionCoordinator.removeListener(sessionListener)
        hideStopOverlay()
        instance.clear()
        super.onDestroy()
    }

    private fun execute(command: RemoteCommand): Boolean {
        if (!CommandGate.accept(command)) return false

        return when (command) {
            is TapCommand -> gesture(
                command.xPx,
                command.yPx,
                command.xPx,
                command.yPx,
                55L
            )
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
        if (
            !fromX.isFinite() ||
            !fromY.isFinite() ||
            !toX.isFinite() ||
            !toY.isFinite()
        ) {
            return false
        }

        val path = Path().apply {
            moveTo(fromX, fromY)
            if (fromX != toX || fromY != toY) {
                lineTo(toX, toY)
            }
        }

        val stroke = GestureDescription.StrokeDescription(
            path,
            0L,
            durationMs
        )

        return dispatchGesture(
            GestureDescription.Builder()
                .addStroke(stroke)
                .build(),
            null,
            null
        )
    }

    private fun showStopOverlay() {
        if (stopOverlay != null) return

        val windowManager = getSystemService(WindowManager::class.java)
        val button = Button(this).apply {
            text = "STOP • LIVE"
            isAllCaps = false
            setOnClickListener {
                startService(
                    Intent(
                        this@AssistAccessibilityService,
                        ScreenShareService::class.java
                    ).apply {
                        action = ScreenShareService.ACTION_STOP
                    }
                )
            }
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = 20
            y = 72
        }

        runCatching {
            windowManager.addView(button, params)
            stopOverlay = button
        }
    }

    private fun hideStopOverlay() {
        val view = stopOverlay ?: return
        stopOverlay = null
        runCatching {
            getSystemService(WindowManager::class.java)
                .removeView(view)
        }
    }

    companion object {
        private var instance = WeakReference<AssistAccessibilityService>(null)

        fun dispatch(command: RemoteCommand): Boolean =
            instance.get()?.execute(command) ?: false

        fun isConnected(): Boolean = instance.get() != null
    }
}
