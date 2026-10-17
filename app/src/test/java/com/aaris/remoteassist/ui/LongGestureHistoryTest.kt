package com.aaris.remoteassist.ui

import android.app.Activity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class LongGestureHistoryTest {
    @Test fun longDragKeepsInitialAnchorAndFreshMotion() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            val view = InlineRemoteControllerView(controller.get(), "long-drag-test") {}
            val append = InlineRemoteControllerView::class.java.getDeclaredMethod(
                "appendGesturePoint",
                Float::class.javaPrimitiveType,
                Float::class.javaPrimitiveType,
                Long::class.javaPrimitiveType
            ).apply { isAccessible = true }

            fun timestamp(point: Any?): Long =
                checkNotNull(point).javaClass.getDeclaredField("atMs")
                    .apply { isAccessible = true }
                    .getLong(point)

            // 320 distinct samples exceed the 192-point bounded buffer.
            repeat(320) { i -> append.invoke(view, i * 10f, 0f, i * 16L) }

            val history = InlineRemoteControllerView::class.java
                .getDeclaredField("gesturePoints")
                .apply { isAccessible = true }
                .get(view) as List<*>

            assertEquals(192, history.size)
            assertEquals(0L, timestamp(history.first()))
            assertEquals(129L * 16L, timestamp(history[1]))
            assertEquals(319L * 16L, timestamp(history.last()))
            assertTrue(history.zipWithNext().all { (a, b) -> timestamp(a) < timestamp(b) })

            val path = InlineRemoteControllerView::class.java
                .getDeclaredMethod("sampledGesturePoints")
                .apply { isAccessible = true }
                .invoke(view) as List<*>
            assertEquals(64, path.size)
            assertEquals(0L, timestamp(path.first()))
            assertEquals(319L * 16L, timestamp(path.last()))
        } finally {
            controller.pause().stop().destroy()
        }
    }
}
