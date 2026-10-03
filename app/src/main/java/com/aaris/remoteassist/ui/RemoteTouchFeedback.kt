package com.aaris.remoteassist.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View

/** Local input marker only; it does not claim the host has applied the action. */
internal class RemoteTouchFeedback(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(105, 195, 255)
        style = Paint.Style.STROKE
        strokeWidth = 2f * resources.displayMetrics.density
    }
    private val xs = FloatArray(2)
    private val ys = FloatArray(2)
    private var count = 0
    private val hide = Runnable { count = 0; invalidate() }

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    fun track(event: MotionEvent) {
        removeCallbacks(hide)
        count = minOf(event.pointerCount, 2)
        for (i in 0 until count) { xs[i] = event.getX(i); ys[i] = event.getY(i) }
        if (event.actionMasked == MotionEvent.ACTION_CANCEL) count = 0
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_POINTER_UP) postDelayed(hide, 120)
        postInvalidateOnAnimation()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val radius = 14f * resources.displayMetrics.density
        for (i in 0 until count) canvas.drawCircle(xs[i], ys[i], radius, paint)
    }

    override fun onDetachedFromWindow() { removeCallbacks(hide); count = 0; super.onDetachedFromWindow() }
}
