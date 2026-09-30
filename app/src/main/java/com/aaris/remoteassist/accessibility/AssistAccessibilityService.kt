package com.aaris.remoteassist.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.graphics.Path
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import com.aaris.remoteassist.capture.ScreenShareService
import com.aaris.remoteassist.control.CommandGate
import com.aaris.remoteassist.control.GlobalAction
import com.aaris.remoteassist.control.GlobalActionCommand
import com.aaris.remoteassist.control.LongPressCommand
import com.aaris.remoteassist.control.RemoteCommand
import com.aaris.remoteassist.control.SetTextCommand
import com.aaris.remoteassist.control.SwipeCommand
import com.aaris.remoteassist.control.TapCommand
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionSnapshot
import com.aaris.remoteassist.session.SessionState
import java.lang.ref.WeakReference

class AssistAccessibilityService : AccessibilityService() {
    private var stopOverlay: View? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val keyguard by lazy {
        getSystemService(KeyguardManager::class.java)
    }

    private val sessionListener: (SessionSnapshot) -> Unit = { snapshot ->
        mainHandler.post {
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
        if (keyguard.isDeviceLocked) return false

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
                    GlobalAction.RECENTS -> GLOBAL_ACTION_RECENTS
                }
            )
            is SetTextCommand -> setFocusedText(command.text)
        }
    }

    private fun setFocusedText(text: String): Boolean {
        val node = rootInActiveWindow
            ?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: return false

        if (!node.isEditable || node.isPassword) return false

        val current = node.text?.toString().orEmpty()
        val selectionStart = node.textSelectionStart
            .takeIf { it >= 0 }
            ?: current.length
        val selectionEnd = node.textSelectionEnd
            .takeIf { it >= 0 }
            ?: selectionStart

        val from = minOf(selectionStart, selectionEnd)
            .coerceIn(0, current.length)
        val to = maxOf(selectionStart, selectionEnd)
            .coerceIn(from, current.length)

        val retainedChars = current.length - (to - from)
        val available =
            (MAX_REMOTE_FIELD_CHARS - retainedChars)
                .coerceAtLeast(0)
        if (available == 0) return false

        val insertion = text
            .take(MAX_REMOTE_TEXT_CHARS)
            .take(available)
        if (insertion.isEmpty()) return false

        val updated = current.replaceRange(
            from,
            to,
            insertion
        )
        val arguments = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                updated
            )
        }

        val applied = node.performAction(
            AccessibilityNodeInfo.ACTION_SET_TEXT,
            arguments
        )
        if (!applied) return false

        val cursor = (from + insertion.length)
            .coerceAtMost(updated.length)
        val selection = Bundle().apply {
            putInt(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT,
                cursor
            )
            putInt(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT,
                cursor
            )
        }
        node.performAction(
            AccessibilityNodeInfo.ACTION_SET_SELECTION,
            selection
        )
        return true
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
        private const val MAX_REMOTE_TEXT_CHARS = 1000
        private const val MAX_REMOTE_FIELD_CHARS = 4000
        private var instance = WeakReference<AssistAccessibilityService>(null)

        fun dispatch(command: RemoteCommand): Boolean =
            instance.get()?.execute(command) ?: false

        fun isConnected(): Boolean = instance.get() != null
    }
}
