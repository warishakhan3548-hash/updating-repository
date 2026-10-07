package com.aaris.remoteassist.debug

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.os.SystemClock
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import kotlin.math.abs
import kotlin.math.roundToInt

internal object E2eMotionState {
    @Volatile var frameCallbacks: Long = 0L
    @Volatile var drawCalls: Long = 0L
    @Volatile var touchEvents: Long = 0L
    @Volatile var gestureStarts: Long = 0L
    @Volatile var gestureEnds: Long = 0L
    @Volatile var lastX: Float = 0f
    @Volatile var lastY: Float = 0f
    @Volatile var lastTouchAtMs: Long = 0L
    @Volatile var startedAtMs: Long = 0L

    fun reset() {
        frameCallbacks = 0L
        drawCalls = 0L
        touchEvents = 0L
        gestureStarts = 0L
        gestureEnds = 0L
        lastX = 0f
        lastY = 0f
        lastTouchAtMs = 0L
        startedAtMs = SystemClock.elapsedRealtime()
    }
}

/**
 * Debug-only deterministic motion surface for dual-emulator end-to-end tests.
 *
 * It generates continuous display motion on the shared phone and records real
 * touch events injected by the remote-controller path. Nothing here is packaged
 * into release builds.
 */
class E2eMotionActivity : Activity() {
    private lateinit var surface: MotionSurface

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        E2eMotionState.reset()
        surface = MotionSurface()
        setContentView(surface)
    }

    override fun onResume() {
        super.onResume()
        surface.start()
    }

    override fun onPause() {
        surface.stop()
        super.onPause()
    }

    private inner class MotionSurface : View(this), Choreographer.FrameCallback {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private var running = false
        private var phase = 0f
        private var markerX = -1f
        private var markerY = -1f

        fun start() {
            if (running) return
            running = true
            Choreographer.getInstance().postFrameCallback(this)
        }

        fun stop() {
            running = false
            Choreographer.getInstance().removeFrameCallback(this)
        }

        override fun doFrame(frameTimeNanos: Long) {
            if (!running) return
            E2eMotionState.frameCallbacks += 1
            phase = (phase + 0.0175f) % 1f
            invalidate()
            Choreographer.getInstance().postFrameCallback(this)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            E2eMotionState.drawCalls += 1

            canvas.drawColor(Color.rgb(12, 14, 18))

            val stripe = (width / 12f).coerceAtLeast(1f)
            for (i in 0..12) {
                paint.color =
                    if (i % 2 == 0) Color.rgb(28, 34, 44)
                    else Color.rgb(18, 22, 29)
                canvas.drawRect(
                    i * stripe,
                    0f,
                    (i + 1) * stripe,
                    height.toFloat(),
                    paint
                )
            }

            val travel = (width - width * 0.20f).coerceAtLeast(1f)
            val x = width * 0.10f + travel * triangleWave(phase)
            val box = (width * 0.11f).coerceAtLeast(36f)
            paint.color = Color.WHITE
            canvas.drawRoundRect(
                x - box / 2f,
                height * 0.28f,
                x + box / 2f,
                height * 0.28f + box,
                box * 0.18f,
                box * 0.18f,
                paint
            )

            val yTravel = height * 0.35f
            val y =
                height * 0.46f +
                    yTravel *
                    triangleWave((phase * 1.37f) % 1f)
            paint.color = Color.rgb(54, 205, 135)
            canvas.drawCircle(
                width * 0.25f,
                y,
                (width * 0.045f).coerceAtLeast(18f),
                paint
            )

            if (markerX >= 0f && markerY >= 0f) {
                paint.color = Color.rgb(255, 185, 65)
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = (width / 150f).coerceAtLeast(3f)
                canvas.drawCircle(markerX, markerY, width * 0.06f, paint)
                paint.style = Paint.Style.FILL
            }

            paint.color = Color.rgb(235, 240, 246)
            paint.textSize = (width / 20f).coerceAtLeast(28f)
            canvas.drawText(
                "AARIS E2E MOTION",
                width * 0.06f,
                height * 0.10f,
                paint
            )
            paint.textSize = (width / 28f).coerceAtLeast(22f)
            canvas.drawText(
                "draw=${E2eMotionState.drawCalls} touch=${E2eMotionState.touchEvents}",
                width * 0.06f,
                height * 0.16f,
                paint
            )
            canvas.drawText(
                "gesture=${E2eMotionState.gestureStarts}/${E2eMotionState.gestureEnds}",
                width * 0.06f,
                height * 0.20f,
                paint
            )
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            E2eMotionState.touchEvents += 1
            E2eMotionState.lastX = event.x
            E2eMotionState.lastY = event.y
            E2eMotionState.lastTouchAtMs = SystemClock.elapsedRealtime()
            markerX = event.x
            markerY = event.y

            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN ->
                    E2eMotionState.gestureStarts += 1
                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_CANCEL ->
                    E2eMotionState.gestureEnds += 1
            }

            invalidate()
            return true
        }

        private fun triangleWave(value: Float): Float {
            val normalized = value - value.toInt()
            return 1f - abs(normalized * 2f - 1f)
        }
    }
}
