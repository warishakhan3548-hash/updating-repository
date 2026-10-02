package com.aaris.remoteassist.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.graphics.Path
import android.graphics.RectF
import android.text.InputType
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import com.aaris.remoteassist.capture.ScreenShareRuntime
import com.aaris.remoteassist.capture.ScreenShareService
import com.aaris.remoteassist.control.CommandGate
import com.aaris.remoteassist.control.GlobalAction
import com.aaris.remoteassist.control.GesturePathCommand
import com.aaris.remoteassist.control.GlobalActionCommand
import com.aaris.remoteassist.control.LongPressCommand
import com.aaris.remoteassist.control.RemoteCommand
import com.aaris.remoteassist.control.SetTextCommand
import com.aaris.remoteassist.control.SwipeCommand
import com.aaris.remoteassist.control.TapCommand
import com.aaris.remoteassist.control.TwoFingerCommand
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionSnapshot
import com.aaris.remoteassist.session.SessionState
import java.lang.ref.WeakReference
import java.util.ArrayDeque

class AssistAccessibilityService : AccessibilityService() {
    private var stopOverlay: View? = null
    private var stopOverlayParams: WindowManager.LayoutParams? = null
    private var stopOverlayWindowManager: WindowManager? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val keyguard by lazy {
        getSystemService(KeyguardManager::class.java)
    }

    private class PendingCommand(
        val command: RemoteCommand,
        private val callback: (Boolean) -> Unit
    ) {
        private var completed = false

        fun complete(applied: Boolean) {
            if (completed) return
            completed = true
            runCatching { callback(applied) }
        }
    }

    private val pendingCommands = ArrayDeque<PendingCommand>()
    private var activeCommand: PendingCommand? = null
    private var activeCommandTimeout: Runnable? = null

    private val sessionListener: (SessionSnapshot) -> Unit = { snapshot ->
        mainHandler.post {
            val sharingOnThisPhone =
                ScreenShareRuntime.isActive(snapshot.sessionId)
            val sharingState =
                snapshot.state == SessionState.SCREEN_CONSENT ||
                    snapshot.state == SessionState.CONNECTING ||
                    snapshot.state == SessionState.LIVE

            if (sharingOnThisPhone && sharingState) {
                showStopOverlay(
                    isLive = snapshot.state == SessionState.LIVE
                )
            } else {
                hideStopOverlay()
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = WeakReference(this)
        SessionCoordinator.addListener(sessionListener)
    }

    override fun onUnbind(intent: Intent?): Boolean {
        SessionCoordinator.removeListener(sessionListener)
        hideStopOverlay()
        failPendingCommands()
        if (instance.get() === this) {
            instance.clear()
        }
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        SessionCoordinator.removeListener(sessionListener)
        hideStopOverlay()
        failPendingCommands()
        if (instance.get() === this) {
            instance.clear()
        }
        super.onDestroy()
    }

    private fun execute(
        command: RemoteCommand,
        onResult: (Boolean) -> Unit
    ) {
        if (!CommandGate.accept(command)) {
            onResult(false)
            return
        }
        if (
            keyguard.isKeyguardLocked ||
            keyguard.isDeviceLocked
        ) {
            onResult(false)
            return
        }

        val gestureBlockedBySensitiveFocus =
            command is TapCommand ||
                command is LongPressCommand ||
                command is SwipeCommand ||
                command is GesturePathCommand ||
                command is TwoFingerCommand

        if (
            gestureBlockedBySensitiveFocus &&
            hasSensitiveFocusedInput()
        ) {
            onResult(false)
            return
        }

        if (
            gestureBlockedBySensitiveFocus &&
            moveStopOverlayAwayFrom(command)
        ) {
            /*
             * WindowManager layout updates cross a process boundary. Give the
             * relocated safety pill one display tick to settle before injecting
             * the gesture so an old overlay surface cannot eat the remote tap.
             */
            mainHandler.postDelayed(
                {
                    performCommand(command, onResult)
                },
                OVERLAY_REPOSITION_SETTLE_MS
            )
            return
        }

        performCommand(command, onResult)
    }

    private fun performCommand(
        command: RemoteCommand,
        onResult: (Boolean) -> Unit
    ) {
        when (command) {
            is TapCommand -> gesture(
                command.xPx,
                command.yPx,
                command.xPx,
                command.yPx,
                40L,
                onResult
            )
            is LongPressCommand -> gesture(
                command.xPx,
                command.yPx,
                command.xPx,
                command.yPx,
                command.durationMs.coerceIn(450L, 1500L),
                onResult
            )
            is SwipeCommand -> gesture(
                command.fromXPx,
                command.fromYPx,
                command.toXPx,
                command.toYPx,
                command.durationMs.coerceIn(80L, 1500L),
                onResult
            )
            is GesturePathCommand -> gesturePath(
                command,
                onResult
            )
            is TwoFingerCommand -> twoFingerGesture(
                command,
                onResult
            )
            is GlobalActionCommand -> onResult(
                performGlobalAction(
                    when (command.action) {
                        GlobalAction.BACK -> GLOBAL_ACTION_BACK
                        GlobalAction.HOME -> GLOBAL_ACTION_HOME
                        GlobalAction.RECENTS -> GLOBAL_ACTION_RECENTS
                    }
                )
            )
            is SetTextCommand -> onResult(
                setFocusedText(command.text)
            )
        }
    }

    private fun hasSensitiveFocusedInput(): Boolean {
        val node = rootInActiveWindow
            ?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: return false

        return node.isEditable && isSensitiveInput(node)
    }

    private fun setFocusedText(text: String): Boolean {
        val node = rootInActiveWindow
            ?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: return false

        if (!node.isEditable || isSensitiveInput(node)) return false

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

    private fun isSensitiveInput(
        node: AccessibilityNodeInfo
    ): Boolean {
        if (node.isPassword) return true

        val inputType = node.inputType
        val inputClass =
            inputType and InputType.TYPE_MASK_CLASS
        val variation =
            inputType and InputType.TYPE_MASK_VARIATION

        if (inputClass == InputType.TYPE_CLASS_TEXT) {
            if (
                variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            ) {
                return true
            }
        }

        if (
            inputClass == InputType.TYPE_CLASS_NUMBER &&
            variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        ) {
            return true
        }

        val metadata = listOfNotNull(
            node.hintText?.toString(),
            node.contentDescription?.toString(),
            node.viewIdResourceName
        ).joinToString(" ")

        return SensitiveFieldHints.isSensitive(metadata)
    }

    private fun gesture(
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long,
        onResult: (Boolean) -> Unit
    ) {
        if (
            !fromX.isFinite() ||
            !fromY.isFinite() ||
            !toX.isFinite() ||
            !toY.isFinite()
        ) {
            onResult(false)
            return
        }

        val path = Path().apply {
            moveTo(fromX, fromY)
            if (fromX != toX || fromY != toY) {
                lineTo(toX, toY)
            }
        }

        dispatchGestureWithResult(
            GestureDescription.Builder()
                .addStroke(
                    GestureDescription.StrokeDescription(
                        path,
                        0L,
                        durationMs
                    )
                )
                .build(),
            onResult
        )
    }

    private fun gesturePath(
        command: GesturePathCommand,
        onResult: (Boolean) -> Unit
    ) {
        if (command.points.size < 2) {
            onResult(false)
            return
        }
        if (
            command.points.any {
                !it.xPx.isFinite() || !it.yPx.isFinite()
            }
        ) {
            onResult(false)
            return
        }

        val first = command.points.first()
        val path = Path().apply {
            moveTo(first.xPx, first.yPx)
            for (index in 1 until command.points.size) {
                val point = command.points[index]
                lineTo(point.xPx, point.yPx)
            }
        }

        val duration = command.durationMs.coerceIn(80L, 1_500L)
        dispatchGestureWithResult(
            GestureDescription.Builder()
                .addStroke(
                    GestureDescription.StrokeDescription(
                        path,
                        0L,
                        duration
                    )
                )
                .build(),
            onResult
        )
    }

    private fun twoFingerGesture(
        command: TwoFingerCommand,
        onResult: (Boolean) -> Unit
    ) {
        val points = floatArrayOf(
            command.firstFromXPx,
            command.firstFromYPx,
            command.firstToXPx,
            command.firstToYPx,
            command.secondFromXPx,
            command.secondFromYPx,
            command.secondToXPx,
            command.secondToYPx
        )
        if (points.any { !it.isFinite() }) {
            onResult(false)
            return
        }

        val duration = command.durationMs.coerceIn(80L, 1_500L)
        fun path(fromX: Float, fromY: Float, toX: Float, toY: Float) =
            Path().apply {
                moveTo(fromX, fromY)
                if (fromX != toX || fromY != toY) {
                    lineTo(toX, toY)
                }
            }

        dispatchGestureWithResult(
            GestureDescription.Builder()
                .addStroke(
                    GestureDescription.StrokeDescription(
                        path(
                            command.firstFromXPx,
                            command.firstFromYPx,
                            command.firstToXPx,
                            command.firstToYPx
                        ),
                        0L,
                        duration
                    )
                )
                .addStroke(
                    GestureDescription.StrokeDescription(
                        path(
                            command.secondFromXPx,
                            command.secondFromYPx,
                            command.secondToXPx,
                            command.secondToYPx
                        ),
                        0L,
                        duration
                    )
                )
                .build(),
            onResult
        )
    }

    private fun dispatchGestureWithResult(
        description: GestureDescription,
        onResult: (Boolean) -> Unit
    ) {
        var delivered = false
        fun deliver(applied: Boolean) {
            if (delivered) return
            delivered = true
            onResult(applied)
        }

        val callback = object :
            AccessibilityService.GestureResultCallback() {
            override fun onCompleted(
                gestureDescription: GestureDescription
            ) {
                deliver(true)
            }

            override fun onCancelled(
                gestureDescription: GestureDescription
            ) {
                deliver(false)
            }
        }

        val accepted = runCatching {
            dispatchGesture(
                description,
                callback,
                mainHandler
            )
        }.getOrDefault(false)

        if (!accepted) {
            deliver(false)
        }
    }

    private fun dispatchOnMain(
        command: RemoteCommand,
        onResult: (Boolean) -> Unit
    ): Boolean {
        val task = Runnable {
            if (instance.get() === this) {
                enqueueCommand(command, onResult)
            } else {
                onResult(false)
            }
        }

        if (Looper.myLooper() == mainHandler.looper) {
            task.run()
            return true
        }

        return mainHandler.post(task)
    }

    private fun enqueueCommand(
        command: RemoteCommand,
        onResult: (Boolean) -> Unit
    ) {
        val pending = PendingCommand(command, onResult)
        val inFlight = if (activeCommand == null) 0 else 1

        if (
            pendingCommands.size + inFlight >=
            MAX_PENDING_COMMANDS
        ) {
            pending.complete(false)
            return
        }

        pendingCommands.addLast(pending)
        drainCommandQueue()
    }

    private fun drainCommandQueue() {
        if (activeCommand != null) return

        val next = pendingCommands.pollFirst() ?: return
        activeCommand = next

        val timeout = Runnable {
            finishCommand(next, false)
        }
        activeCommandTimeout = timeout
        mainHandler.postDelayed(
            timeout,
            COMMAND_EXECUTION_TIMEOUT_MS
        )

        execute(next.command) { applied ->
            finishCommand(next, applied)
        }
    }

    private fun finishCommand(
        pending: PendingCommand,
        applied: Boolean
    ) {
        if (Looper.myLooper() != mainHandler.looper) {
            val posted = mainHandler.post {
                finishCommand(pending, applied)
            }
            if (!posted) {
                pending.complete(false)
            }
            return
        }

        pending.complete(applied)
        if (activeCommand === pending) {
            activeCommandTimeout?.let(
                mainHandler::removeCallbacks
            )
            activeCommandTimeout = null
            activeCommand = null
            drainCommandQueue()
        }
    }

    private fun failPendingCommands() {
        activeCommandTimeout?.let(
            mainHandler::removeCallbacks
        )
        activeCommandTimeout = null
        activeCommand?.complete(false)
        activeCommand = null

        while (pendingCommands.isNotEmpty()) {
            pendingCommands.removeFirst().complete(false)
        }
    }

    private fun moveStopOverlayAwayFrom(
        command: RemoteCommand
    ): Boolean {
        val view = stopOverlay ?: return false
        val params = stopOverlayParams ?: return false
        val windowManager =
            stopOverlayWindowManager ?: return false
        if (
            view.width <= 0 ||
            view.height <= 0
        ) {
            return false
        }

        val points: List<Pair<Float, Float>> =
            when (command) {
                is TapCommand ->
                    listOf(command.xPx to command.yPx)

                is LongPressCommand ->
                    listOf(command.xPx to command.yPx)

                is SwipeCommand ->
                    listOf(
                        command.fromXPx to command.fromYPx,
                        command.toXPx to command.toYPx
                    )

                is GesturePathCommand ->
                    command.points.map {
                        it.xPx to it.yPx
                    }

                is TwoFingerCommand ->
                    listOf(
                        command.firstFromXPx to command.firstFromYPx,
                        command.firstToXPx to command.firstToYPx,
                        command.secondFromXPx to command.secondFromYPx,
                        command.secondToXPx to command.secondToYPx
                    )

                is GlobalActionCommand,
                is SetTextCommand ->
                    return false
            }

        if (points.isEmpty()) return false

        val clearance =
            REMOTE_OVERLAY_CLEARANCE_DP *
                resources.displayMetrics.density
        val minX =
            points.minOf { it.first } - clearance
        val maxX =
            points.maxOf { it.first } + clearance
        val minY =
            points.minOf { it.second } - clearance
        val maxY =
            points.maxOf { it.second } + clearance
        val commandBounds =
            RectF(minX, minY, maxX, maxY)

        val currentLocation = IntArray(2)
        view.getLocationOnScreen(currentLocation)
        val currentBounds =
            RectF(
                currentLocation[0].toFloat(),
                currentLocation[1].toFloat(),
                (currentLocation[0] + view.width).toFloat(),
                (currentLocation[1] + view.height).toFloat()
            )
        if (!RectF.intersects(currentBounds, commandBounds)) {
            return false
        }

        val metrics = resources.displayMetrics
        val screenWidth = metrics.widthPixels
        val screenHeight = metrics.heightPixels
        val maxParamX =
            (screenWidth - view.width).coerceAtLeast(0)
        val maxParamY =
            (screenHeight - view.height).coerceAtLeast(0)
        val margin =
            (
                OVERLAY_EDGE_MARGIN_DP *
                    metrics.density
                ).toInt()
                .coerceAtLeast(0)
        val nearX = margin.coerceAtMost(maxParamX)
        val farX =
            (maxParamX - margin)
                .coerceAtLeast(0)
        val nearY = margin.coerceAtMost(maxParamY)
        val farY =
            (maxParamY - margin)
                .coerceAtLeast(0)

        val candidates =
            listOf(
                nearX to nearY,
                farX to nearY,
                nearX to farY,
                farX to farY
            ).distinct()

        val commandCenterX =
            (commandBounds.left + commandBounds.right) / 2f
        val commandCenterY =
            (commandBounds.top + commandBounds.bottom) / 2f

        val best =
            candidates.maxByOrNull { (candidateX, candidateY) ->
                /*
                 * Gravity.END means LayoutParams.x is the distance from the
                 * right edge, not an absolute left coordinate.
                 */
                val left =
                    screenWidth -
                        view.width -
                        candidateX
                val top = candidateY
                val candidateBounds =
                    RectF(
                        left.toFloat(),
                        top.toFloat(),
                        (left + view.width).toFloat(),
                        (top + view.height).toFloat()
                    )
                val clear =
                    !RectF.intersects(
                        candidateBounds,
                        commandBounds
                    )
                val centerX =
                    candidateBounds.centerX()
                val centerY =
                    candidateBounds.centerY()
                val dx = centerX - commandCenterX
                val dy = centerY - commandCenterY
                (
                    if (clear) CLEAR_CANDIDATE_BONUS else 0f
                    ) +
                    dx * dx +
                    dy * dy
            } ?: return false

        if (
            params.x == best.first &&
            params.y == best.second
        ) {
            return false
        }

        params.x = best.first
        params.y = best.second
        return runCatching {
            windowManager.updateViewLayout(
                view,
                params
            )
        }.isSuccess
    }

    private fun showStopOverlay(isLive: Boolean) {
        val label =
            if (isLive) {
                "STOP"
            } else {
                "STOP • CONNECTING"
            }

        (stopOverlay as? Button)?.let { existing ->
            if (existing.text.toString() != label) {
                existing.text = label
            }
            return
        }

        val windowManager = getSystemService(WindowManager::class.java)
        val button = Button(this).apply {
            text = label
            isAllCaps = false
            minimumWidth = 0
            minimumHeight = 0
            textSize = 12f
            val density = resources.displayMetrics.density
            setPadding(
                (12f * density).toInt(),
                (6f * density).toInt(),
                (12f * density).toInt(),
                (6f * density).toInt()
            )
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

        /*
         * The safety control must always remain reachable, but it must not
         * permanently make the app underneath untappable. A tap still stops
         * sharing; dragging moves the pill away from whatever the remote user
         * needs to press.
         */
        val touchSlop =
            ViewConfiguration.get(this).scaledTouchSlop.toFloat()
        var downRawX = 0f
        var downRawY = 0f
        var startX = 0
        var startY = 0
        var dragging = false

        button.contentDescription =
            "Stop sharing. Drag to move this button."
        button.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    dragging = false
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY

                    if (
                        !dragging &&
                        dx * dx + dy * dy >=
                        touchSlop * touchSlop
                    ) {
                        dragging = true
                    }

                    if (dragging) {
                        val metrics = resources.displayMetrics
                        val maxX =
                            (metrics.widthPixels - view.width)
                                .coerceAtLeast(0)
                        val maxY =
                            (metrics.heightPixels - view.height)
                                .coerceAtLeast(0)

                        // Gravity.END means positive x moves inward from right.
                        params.x =
                            (startX - dx.toInt())
                                .coerceIn(0, maxX)
                        params.y =
                            (startY + dy.toInt())
                                .coerceIn(0, maxY)

                        runCatching {
                            windowManager.updateViewLayout(
                                button,
                                params
                            )
                        }
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (!dragging) {
                        view.performClick()
                    }
                    true
                }

                MotionEvent.ACTION_CANCEL -> {
                    dragging = false
                    true
                }

                else -> true
            }
        }

        runCatching {
            windowManager.addView(button, params)
            stopOverlay = button
            stopOverlayParams = params
            stopOverlayWindowManager = windowManager
        }
    }

    private fun hideStopOverlay() {
        val view = stopOverlay ?: return
        val windowManager =
            stopOverlayWindowManager
                ?: getSystemService(WindowManager::class.java)
        stopOverlay = null
        stopOverlayParams = null
        stopOverlayWindowManager = null
        runCatching {
            windowManager.removeView(view)
        }
    }

    companion object {
        private const val MAX_REMOTE_TEXT_CHARS = 1000
        private const val MAX_REMOTE_FIELD_CHARS = 4000
        private const val MAX_PENDING_COMMANDS = 16
        private const val COMMAND_EXECUTION_TIMEOUT_MS = 3_000L
        private const val REMOTE_OVERLAY_CLEARANCE_DP = 18f
        private const val OVERLAY_EDGE_MARGIN_DP = 16f
        private const val CLEAR_CANDIDATE_BONUS = 1_000_000_000f
        private const val OVERLAY_REPOSITION_SETTLE_MS = 16L
        @Volatile
        private var instance = WeakReference<AssistAccessibilityService>(null)

        fun dispatch(
            command: RemoteCommand,
            onResult: (Boolean) -> Unit
        ): Boolean {
            val service = instance.get()
            if (service == null) {
                onResult(false)
                return false
            }

            val queued = service.dispatchOnMain(
                command,
                onResult
            )
            if (!queued) {
                onResult(false)
            }
            return queued
        }

        fun isConnected(): Boolean = instance.get() != null
    }
}
