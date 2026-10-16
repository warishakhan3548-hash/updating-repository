package com.aaris.remoteassist.ui

import android.app.Activity
import android.graphics.Bitmap
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.widget.ImageView
import com.aaris.remoteassist.webrtc.PassiveMotionPriority
import com.aaris.remoteassist.webrtc.PresentationCadenceTracker
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import org.robolectric.shadows.ShadowSystemClock
import org.webrtc.EglRenderer

/** Exercise the production listener/lifecycle with a controllable EGL lane. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
@LooperMode(LooperMode.Mode.PAUSED)
class ControllerSurfaceLifecycleTest {
    private class Renderer : EglRenderer("surface-lifecycle-test") {
        lateinit var listener: EglRenderer.RenderListener
        var releaseSurface: (Runnable) -> Unit = { it.run() }
        var onRelease: () -> Unit = {}

        override fun addRenderListener(listener: EglRenderer.RenderListener) {
            this.listener = listener
        }

        override fun releaseEglSurface(completionCallback: Runnable) {
            releaseSurface(completionCallback)
        }

        override fun release() = onRelease()
    }

    private class Fixture {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val view = InlineRemoteControllerView(activity.get(), "surface-lifecycle-test") {}
        val renderer = Renderer()
        val egl = Executors.newSingleThreadExecutor()

        init {
            set("attached", true)
            set("eglRenderer", renderer)
            set("rendererSurfaceAttached", true)
            call("installPresentationListener", renderer)
            ShadowSystemClock.advanceBy(Duration.ofSeconds(1))
        }

        fun field(name: String) =
            InlineRemoteControllerView::class.java.getDeclaredField(name)
                .apply { isAccessible = true }

        fun get(name: String): Any? = field(name).get(view)

        fun set(name: String, value: Any?) = field(name).set(view, value)

        fun call(name: String, vararg args: Any) {
            val types = args.map { if (it is EglRenderer) EglRenderer::class.java else it.javaClass }
            InlineRemoteControllerView::class.java.getDeclaredMethod(name, *types.toTypedArray())
                .apply { isAccessible = true }.invoke(view, *args)
        }

        fun present() {
            egl.submit { renderer.listener.onRender(System.nanoTime()) }
                .get(5, TimeUnit.SECONDS)
        }

        fun close() {
            view.hide()
            egl.shutdownNow()
            assertTrue(egl.awaitTermination(5, TimeUnit.SECONDS))
            shadowOf(Looper.getMainLooper()).idle()
            activity.pause().stop().destroy()
        }
    }

    @Test fun surfaceDestructionWaitsForEglCompletionBeforeChangingEpoch() {
        val fixture = Fixture()
        val releaseRequested = CountDownLatch(1)
        val completion = AtomicReference<Runnable>()
        val lifecycle = Executors.newSingleThreadExecutor()
        val epoch = fixture.get("recoveryGeneration") as AtomicLong
        val before = epoch.get()
        fixture.renderer.releaseSurface = {
            completion.set(it)
            releaseRequested.countDown()
        }
        val destruction = lifecycle.submit { fixture.call("releaseRendererSurface") }
        try {
            assertTrue(releaseRequested.await(5, TimeUnit.SECONDS))
            assertFalse(fixture.get("rendererSurfaceAttached") as Boolean)
            assertThrows(TimeoutException::class.java) {
                destruction.get(100, TimeUnit.MILLISECONDS)
            }
            assertEquals("An in-flight old swap must not acquire a new epoch", before, epoch.get())
            fixture.present()
            assertEquals("A swap on the Surface being released is not current presentation",
                0L, fixture.get("lastPresentedFrameAtMs"))

            // EGL completion never needs the main looper that destruction is
            // allowed to block. Only this native-lane signal releases the fence.
            fixture.egl.submit { completion.get().run() }.get(5, TimeUnit.SECONDS)
            destruction.get(5, TimeUnit.SECONDS)
            assertEquals(before + 1L, epoch.get())
            assertSame("Surface loss preserves the renderer/decoder transport", fixture.renderer,
                fixture.get("eglRenderer"))
        } finally {
            completion.get()?.run()
            lifecycle.shutdownNow()
            assertTrue(lifecycle.awaitTermination(5, TimeUnit.SECONDS))
            fixture.renderer.releaseSurface = { it.run() }
            fixture.close()
        }
    }

    @Test fun queuedOldSurfaceSwapCannotHideFallbackAfterSurfaceRecreation() {
        val fixture = Fixture()
        val main = shadowOf(Looper.getMainLooper())
        val fallback = fixture.get("fallbackImageView") as ImageView
        try {
            fixture.set("fallbackActive", true)
            fallback.visibility = View.VISIBLE
            fixture.present() // First-swap commit is queued on the paused UI.
            fixture.call("releaseRendererSurface")
            fixture.set("rendererSurfaceAttached", true)
            main.idle()

            assertFalse((fixture.get("renderedFrameSeen") as AtomicBoolean).get())
            assertTrue(fixture.get("fallbackActive") as Boolean)
            assertEquals(View.VISIBLE, fallback.visibility)

            fixture.present()
            main.idle()
            assertTrue((fixture.get("renderedFrameSeen") as AtomicBoolean).get())
            assertFalse(fixture.get("fallbackActive") as Boolean)
            assertEquals(View.GONE, fallback.visibility)
        } finally {
            fixture.close()
        }
    }

    @Test fun firstNewSurfaceSwapCanConfirmWhileOldConfirmationIsStillQueued() {
        val fixture = Fixture()
        try {
            fixture.present()
            fixture.call("releaseRendererSurface")
            fixture.set("rendererSurfaceAttached", true)
            fixture.present() // Do not drain the obsolete UI callback first.
            shadowOf(Looper.getMainLooper()).idle()

            assertTrue("The new Surface must not wait for another decoded frame",
                (fixture.get("renderedFrameSeen") as AtomicBoolean).get())
            assertEquals(-1L, (fixture.get("renderConfirmationGeneration") as AtomicLong).get())
        } finally {
            fixture.close()
        }
    }

    @Test fun surfaceLossResetsHealthButPreservesDecodedTrackEvidence() {
        val fixture = Fixture()
        val cadence = fixture.get("presentationCadence") as PresentationCadenceTracker
        val confirmation = fixture.get("primaryConfirmation") as PrimaryVideoConfirmation
        val passive = fixture.get("passiveRenderMotion") as PassiveMotionPriority
        val now = SystemClock.elapsedRealtime()
        var confirmations = 0
        try {
            fixture.present()
            shadowOf(Looper.getMainLooper()).idle()
            fixture.set("lastRawFrameAtMs", now)
            (fixture.get("rawFrameSeen") as AtomicBoolean).set(true)
            confirmation.reset()
            confirmation.onPresented(now) { confirmations++; true }
            passive.pulse(now)
            fixture.set("renderPassivePriorityActive", true)

            fixture.call("releaseRendererSurface")
            assertEquals(0L, fixture.get("lastPresentedFrameAtMs"))
            assertFalse((fixture.get("renderedFrameSeen") as AtomicBoolean).get())
            assertFalse(fixture.get("renderPassivePriorityActive") as Boolean)
            assertFalse(passive.isActive(now))
            assertTrue((fixture.get("rawFrameSeen") as AtomicBoolean).get())
            assertEquals(now, fixture.get("lastRawFrameAtMs"))
            assertEquals(Long.MIN_VALUE / 2,
                (fixture.get("lastPresentationHeartbeatAtMs") as AtomicLong).get())
            confirmation.onPresented(now + 1) { confirmations++; true }
            assertEquals("Primary-video confirmation must be rearmed", 2, confirmations)

            // A normal short hidden-Surface pause must not become a giant
            // decoder/network maxGap report on the replacement Surface.
            ShadowSystemClock.advanceBy(Duration.ofSeconds(2))
            fixture.set("rendererSurfaceAttached", true)
            fixture.present()
            val resumedAt = SystemClock.elapsedRealtime()
            val sample = cadence.onPresented(resumedAt + 500)
            assertNotNull(sample)
            assertEquals(500, sample!!.intervalMs)
            assertEquals(1, sample.renderedFrames)
            assertEquals(500, sample.maxGapMs)
        } finally {
            fixture.close()
        }
    }

    @Test fun rebuildFencesTheOldRendererAndResetsTheSamePresentationEvidence() {
        val fixture = Fixture()
        val epoch = fixture.get("recoveryGeneration") as AtomicLong
        val cadence = fixture.get("presentationCadence") as PresentationCadenceTracker
        val before = epoch.get()
        var released = false
        try {
            fixture.present()
            fixture.renderer.onRelease = {
                assertEquals(before, epoch.get())
                // A pending old EGL callback observes a detached renderer.
                fixture.egl.submit { fixture.renderer.listener.onRender(System.nanoTime()) }
                    .get(5, TimeUnit.SECONDS)
                released = true
            }
            fixture.call("rebuildRenderer")
            assertTrue(released)
            assertEquals(before + 1, epoch.get())
            assertNull(fixture.get("eglRenderer"))
            assertFalse(fixture.get("rendererSurfaceAttached") as Boolean)
            assertEquals(0L, fixture.get("lastPresentedFrameAtMs"))
            assertFalse((fixture.get("renderedFrameSeen") as AtomicBoolean).get())
            assertNull(cadence.onPresented(SystemClock.elapsedRealtime() + 2_000))
            shadowOf(Looper.getMainLooper()).idle()
            assertFalse((fixture.get("renderedFrameSeen") as AtomicBoolean).get())
        } finally {
            fixture.close()
        }
    }
    @Test fun fallbackUiCommitReplacesQueuedJpegBitmaps() {
        val fixture = Fixture()
        val main = shadowOf(Looper.getMainLooper())
        val enqueue = InlineRemoteControllerView::class.java.getDeclaredMethod(
            "enqueueFallbackUiBitmap",
            java.lang.Long.TYPE,
            Bitmap::class.java
        ).apply { isAccessible = true }
        val frames = (1..24).map {
            Bitmap.createBitmap(16, 20, Bitmap.Config.ARGB_8888)
        }
        try {
            // A paused UI is intentionally slower than the fallback decoder.
            // Only the latest already-decoded JPEG may survive the backlog.
            frames.forEachIndexed { index, bitmap ->
                enqueue.invoke(fixture.view, (index + 1).toLong(), bitmap)
            }
            assertTrue(frames.dropLast(1).all { it.isRecycled })
            assertEquals(-1L, fixture.get("fallbackCompositeFrameId"))
            main.idle()
            assertEquals(24L, fixture.get("fallbackCompositeFrameId"))
            assertSame(frames.last(), fixture.get("fallbackBitmap"))
            assertFalse(frames.last().isRecycled)
        } finally {
            fixture.close()
            assertTrue(frames.all { it.isRecycled })
        }
    }

    @Test fun hidingControllerRecyclesQueuedFallbackBitmapWithoutUiCommit() {
        val fixture = Fixture()
        val main = shadowOf(Looper.getMainLooper())
        val enqueue = InlineRemoteControllerView::class.java.getDeclaredMethod(
            "enqueueFallbackUiBitmap",
            java.lang.Long.TYPE,
            Bitmap::class.java
        ).apply { isAccessible = true }
        val image = Bitmap.createBitmap(16, 20, Bitmap.Config.ARGB_8888)
        try {
            enqueue.invoke(fixture.view, 7L, image)
            assertFalse(image.isRecycled)
            fixture.view.hide()
            assertTrue("Pending JPEG memory must be freed at session end", image.isRecycled)
            main.idle()
            assertEquals(-1L, fixture.get("fallbackCompositeFrameId"))
            assertNull(fixture.get("fallbackBitmap"))
        } finally {
            fixture.close()
        }
    }

}
