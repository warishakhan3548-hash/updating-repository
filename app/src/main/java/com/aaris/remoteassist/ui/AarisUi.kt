package com.aaris.remoteassist.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import android.widget.Button
import android.widget.ProgressBar

internal object AarisUi {
    val CANVAS: Int = Color.rgb(245, 247, 251)
    val SURFACE: Int = Color.WHITE
    val SURFACE_MUTED: Int = Color.rgb(248, 250, 252)
    val PRIMARY: Int = Color.rgb(37, 99, 235)
    val PRIMARY_DARK: Int = Color.rgb(29, 78, 216)
    val ON_PRIMARY: Int = Color.WHITE
    val TEXT_PRIMARY: Int = Color.rgb(15, 23, 42)
    val TEXT_SECONDARY: Int = Color.rgb(71, 85, 105)
    val TEXT_TERTIARY: Int = Color.rgb(100, 116, 139)
    val BORDER: Int = Color.rgb(226, 232, 240)
    val DANGER: Int = Color.rgb(185, 28, 28)

    val REMOTE_CANVAS: Int = Color.rgb(3, 7, 18)
    val REMOTE_PANEL: Int = Color.argb(232, 15, 23, 42)
    val REMOTE_BORDER: Int = Color.argb(110, 148, 163, 184)
    val REMOTE_ACCENT: Int = Color.rgb(96, 165, 250)
    private val REMOTE_DANGER: Int = Color.rgb(248, 113, 113)

    fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density).toInt()

    fun panel(
        context: Context,
        fill: Int,
        radiusDp: Int,
        strokeColor: Int? = null,
        strokeWidthDp: Int = 1
    ): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(fill)
        cornerRadius = dp(context, radiusDp).toFloat()
        if (strokeColor != null) {
            setStroke(
                dp(context, strokeWidthDp).coerceAtLeast(1),
                strokeColor
            )
        }
    }

    private fun interactiveSurface(
        context: Context,
        fill: Int,
        ripple: Int,
        radiusDp: Int,
        strokeColor: Int? = null
    ): RippleDrawable {
        val content = panel(
            context = context,
            fill = fill,
            radiusDp = radiusDp,
            strokeColor = strokeColor
        )
        return RippleDrawable(
            ColorStateList.valueOf(ripple),
            content,
            null
        )
    }

    fun primaryButton(button: Button) {
        val context = button.context
        button.isAllCaps = false
        button.textSize = 16f
        button.setTextColor(ON_PRIMARY)
        button.typeface = Typeface.create(
            "sans-serif-medium",
            Typeface.NORMAL
        )
        button.background = interactiveSurface(
            context = context,
            fill = PRIMARY,
            ripple = PRIMARY_DARK,
            radiusDp = 18
        )
        button.elevation = dp(context, 2).toFloat()
        button.minWidth = 0
        button.minimumWidth = 0
        button.minHeight = 0
        button.minimumHeight = 0
        button.setPadding(
            dp(context, 18),
            dp(context, 12),
            dp(context, 18),
            dp(context, 12)
        )
    }

    fun secondaryButton(button: Button) {
        val context = button.context
        button.isAllCaps = false
        button.textSize = 16f
        button.setTextColor(PRIMARY)
        button.typeface = Typeface.create(
            "sans-serif-medium",
            Typeface.NORMAL
        )
        button.background = interactiveSurface(
            context = context,
            fill = SURFACE,
            ripple = Color.rgb(219, 234, 254),
            radiusDp = 18,
            strokeColor = Color.rgb(191, 219, 254)
        )
        button.elevation = dp(context, 1).toFloat()
        button.minWidth = 0
        button.minimumWidth = 0
        button.minHeight = 0
        button.minimumHeight = 0
        button.setPadding(
            dp(context, 18),
            dp(context, 12),
            dp(context, 18),
            dp(context, 12)
        )
    }

    fun remoteDockButton(
        button: Button,
        danger: Boolean
    ) {
        val context = button.context
        val textColor =
            if (danger) REMOTE_DANGER else Color.WHITE
        val fill =
            if (danger) Color.argb(64, 248, 113, 113)
            else Color.TRANSPARENT
        val ripple =
            if (danger) Color.argb(96, 248, 113, 113)
            else Color.argb(70, 148, 163, 184)

        button.isAllCaps = false
        button.textSize = 12f
        button.setTextColor(textColor)
        button.typeface = Typeface.create(
            "sans-serif-medium",
            Typeface.NORMAL
        )
        button.background = interactiveSurface(
            context = context,
            fill = fill,
            ripple = ripple,
            radiusDp = 16
        )
        button.minWidth = 0
        button.minimumWidth = 0
        button.minHeight = 0
        button.minimumHeight = 0
        button.setPadding(
            dp(context, 13),
            dp(context, 10),
            dp(context, 13),
            dp(context, 10)
        )
    }

    fun tintProgress(
        progressBar: ProgressBar,
        color: Int
    ) {
        progressBar.indeterminateTintList =
            ColorStateList.valueOf(color)
    }

    fun haptic(view: View) {
        val feedback =
            if (Build.VERSION.SDK_INT >= 30) {
                HapticFeedbackConstants.CONFIRM
            } else {
                HapticFeedbackConstants.VIRTUAL_KEY
            }
        view.performHapticFeedback(feedback)
    }
}
