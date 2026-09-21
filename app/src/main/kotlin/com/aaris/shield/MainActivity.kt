package com.aaris.shield

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import com.aaris.shield.core.ShieldComponentId
import com.aaris.shield.core.ShieldComponentSnapshot
import com.aaris.shield.core.ShieldComponentState
import com.aaris.shield.core.ShieldRuntimeRegistry

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val registry = ShieldRuntimeRegistry(
            listOf(
                ShieldComponentSnapshot(
                    id = ShieldComponentId.FOUNDATION,
                    state = ShieldComponentState.READY,
                    detail = "Architecture foundation active",
                ),
            ),
        )

        val foundation = requireNotNull(registry.get(ShieldComponentId.FOUNDATION))
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
            addView(TextView(context).apply {
                text = getString(R.string.app_name)
                textSize = 28f
                gravity = Gravity.CENTER
            })
            addView(TextView(context).apply {
                text = "${foundation.detail}. Protection modules are not enabled yet."
                textSize = 16f
                gravity = Gravity.CENTER
            })
        }
        setContentView(content)
    }
}
