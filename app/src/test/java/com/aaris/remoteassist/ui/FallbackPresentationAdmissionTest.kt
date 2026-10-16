package com.aaris.remoteassist.ui

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import com.aaris.remoteassist.webrtc.FallbackDeltaFrame
import com.aaris.remoteassist.webrtc.FallbackVideoFrame
import com.aaris.remoteassist.webrtc.RemoteGeometry
import java.io.ByteArrayOutputStream
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.annotation.LooperMode

/** Run the real decode/commit path with independently controlled worker and UI lanes. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@LooperMode(LooperMode.Mode.PAUSED)
class FallbackPresentationAdmissionTest {
    private class Worker : AbstractExecutorService() {
        private val tasks = ArrayDeque<Runnable>()
        private var stopped = false
        var executed = 0
            private set
        val queued: Int get() = tasks.size

        override fun execute(command: Runnable) {
            if (stopped) throw RejectedExecutionException()
            tasks.addLast(command)
        }

        fun runNext() {
            executed++
            tasks.removeFirst().run()
        }

        override fun shutdown() { stopped = true }
        override fun shutdownNow(): MutableList<Runnable> {
            stopped = true
            return tasks.toMutableList().also { tasks.clear() }
        }
        override fun isShutdown() = stopped
        override fun isTerminated() = stopped && tasks.isEmpty()
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = isTerminated
    }

    private class Fixture : AutoCloseable {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val view = InlineRemoteControllerView(activity.get(), "fallback-admission-test") {}
        val main = shadowOf(Looper.getMainLooper())
        val worker = Worker()
        val jpeg: ByteArray

        init {
            (get("fallbackDecoder") as ExecutorService).shutdownNow()
            set("fallbackDecoder", worker)
            set("attached", true)
            set("geometry", RemoteGeometry(1, 20, 40))
            val source = bitmap()
            jpeg = ByteArrayOutputStream().also {
                assertTrue(source.compress(Bitmap.CompressFormat.JPEG, 90, it))
            }.toByteArray()
            source.recycle()
            main.idle()
        }

        fun get(name: String): Any? = field(name).get(view)
        fun set(name: String, value: Any?) = field(name).set(view, value)
        private fun field(name: String) =
            InlineRemoteControllerView::class.java.getDeclaredField(name)
                .apply { isAccessible = true }

        fun call(name: String, vararg args: Any): Any? =
            InlineRemoteControllerView::class.java.getDeclaredMethod(
                name, *args.map { it.javaClass }.toTypedArray()
            ).apply { isAccessible = true }.invoke(view, *args)

        fun frame(id: Long) = FallbackVideoFrame(id, 20, 40, 0, jpeg)
        fun admit(id: Long) { call("decodeFallbackFrame", frame(id)) }
        fun scheduled() = (get("fallbackDecodeScheduled") as AtomicBoolean).get()
        fun pending() =
            (get("pendingFallbackFrame") as AtomicReference<*>).get() as FallbackVideoFrame?
        fun composite() = get("fallbackCompositeFrameId") as Long
        fun delta(id: Long, base: Long) {
            call("decodeFallbackDeltaFrame", FallbackDeltaFrame(id, base, 20, 40, 0, 0, 0, emptyList()))
        }
        fun deltasInFlight() = (get("deltaFramesInFlight") as AtomicInteger).get()
        fun deferredDeltas() = (get("deferredFallbackDeltas") as Collection<*>).size
        fun bitmap() = Bitmap.createBitmap(20, 40, Bitmap.Config.ARGB_8888)
            .apply { eraseColor(Color.RED) }

        override fun close() {
            view.hide()
            main.idle()
            activity.pause().stop().destroy()
        }
    }

    @Test fun blockedUiKeepsOneDecodedAnchorAndOnlyTheNewestPendingJpeg() {
        Fixture().use { f ->
            f.admit(1)
            f.worker.runNext() // The first decoded bitmap now waits on the paused UI.
            for (id in 2L..100L) f.admit(id)

            assertTrue("UI ownership must keep the decoder permit", f.scheduled())
            assertEquals("No additional decoded bitmaps may be queued", 1, f.worker.executed)
            assertEquals(0, f.worker.queued)
            assertEquals(100L, f.pending()!!.frameId)
            assertEquals(-1L, f.composite())

            f.main.runOneTask()
            assertEquals(1L, f.composite())
            val firstBitmap = f.get("fallbackBitmap") as Bitmap
            assertEquals(1, f.worker.queued)
            f.worker.runNext()
            assertEquals(2, f.worker.executed)
            assertTrue(f.scheduled())
            f.main.idle()

            assertEquals(100L, f.composite())
            assertTrue("Replacing the displayed anchor releases its pixels", firstBitmap.isRecycled)
            assertNull(f.pending())
            assertFalse(f.scheduled())
        }
    }

    @Test fun queuedDeltaRunsBetweenAnchorsAndCommitsBeforeTheLaterAnchor() {
        Fixture().use { f ->
            f.admit(1)
            f.worker.runNext()
            f.delta(2, 1)
            f.admit(3)
            assertEquals(0, f.worker.queued)

            f.main.runOneTask()
            assertEquals(1L, f.composite())
            assertEquals("Anchor completion admits its older delta before the next anchor", 2, f.worker.queued)
            f.worker.runNext() // Delta's commit is queued after anchor 1.
            f.worker.runNext() // Anchor 3's callback must stay after delta 2.
            f.main.runOneTask()
            assertEquals("A newer anchor cannot steal an older callback", 2L, f.composite())
            f.main.runOneTask()
            assertEquals(3L, f.composite())
            assertFalse(f.scheduled())
        }
    }

    @Test fun pendingAnchorCommitsBeforeItsDeferredDeltaChainWithUiBlocked() {
        Fixture().use { f ->
            f.admit(1)
            f.worker.runNext()
            f.admit(3)
            f.delta(4, 3)
            f.delta(5, 4)
            assertEquals(2, f.deferredDeltas())
            assertEquals(2, f.deltasInFlight())
            assertEquals("Dependent deltas cannot overtake the pending full anchor", 0, f.worker.queued)

            f.main.runOneTask() // Anchor 1 releases full-anchor admission.
            f.worker.runNext() // Decode anchor 3, still no delta work admitted.
            assertEquals(0, f.worker.queued)
            f.main.runOneTask()
            assertEquals(3L, f.composite())
            assertEquals(0, f.deferredDeltas())
            assertEquals(2, f.worker.queued)
            f.worker.runNext()
            f.worker.runNext()
            f.main.runOneTask()
            assertEquals(4L, f.composite())
            f.main.runOneTask()
            assertEquals(5L, f.composite())
            assertEquals(0, f.deltasInFlight())
        }
    }

    @Test fun replacingPendingAnchorDiscardsItsChainAndAdmitsTheNewCheckpoint() {
        Fixture().use { f ->
            f.admit(1)
            f.worker.runNext()
            f.admit(3)
            f.delta(4, 3)
            f.delta(5, 4)
            f.admit(6)
            assertEquals("Replaced dependencies release their shared delta permits", 0, f.deltasInFlight())
            assertEquals(0, f.deferredDeltas())
            f.delta(7, 6)

            f.main.runOneTask()
            f.worker.runNext()
            f.main.runOneTask()
            assertEquals(6L, f.composite())
            f.worker.runNext()
            f.main.runOneTask()
            assertEquals(7L, f.composite())
            assertEquals(0, f.deltasInFlight())
        }
    }

    @Test fun deferredPacketsShareTheExistingThreeDeltaLimit() {
        Fixture().use { f ->
            f.admit(1)
            f.worker.runNext()
            f.admit(3)
            f.delta(4, 3)
            f.delta(5, 4)
            f.delta(6, 5)
            f.delta(7, 6)
            assertEquals(3, f.deferredDeltas())
            assertEquals(3, f.deltasInFlight())
            assertEquals(0, f.worker.queued)

            f.main.idle() // Anchor 1 plus the throttled missing-dependency request.
            f.worker.runNext()
            f.main.idle()
            repeat(3) { f.worker.runNext() }
            f.main.idle()
            assertEquals(6L, f.composite())
            assertEquals(0, f.deltasInFlight())
        }
    }

    @Test fun invalidPendingAnchorDropsItsDependentChainWithoutStrandingPermits() {
        Fixture().use { f ->
            f.admit(1)
            f.worker.runNext()
            f.call("decodeFallbackFrame", f.frame(3).copy(jpeg = byteArrayOf(1, 2, 3)))
            f.delta(4, 3)
            f.delta(5, 4)
            f.main.runOneTask()
            f.worker.runNext()
            assertFalse(f.scheduled())
            assertEquals(0, f.deferredDeltas())
            assertEquals(0, f.deltasInFlight())

            f.admit(6)
            f.worker.runNext()
            f.main.idle()
            assertEquals(6L, f.composite())
        }
    }

    @Test fun invalidDecodeReleasesPermitAndTheNextAnchorCanProgress() {
        Fixture().use { f ->
            f.call("decodeFallbackFrame", f.frame(1).copy(jpeg = byteArrayOf(1, 2, 3)))
            f.worker.runNext()
            assertFalse(f.scheduled())
            assertNull(f.get("fallbackBitmap"))

            f.admit(2)
            f.worker.runNext()
            f.main.idle()
            assertEquals(2L, f.composite())
            assertFalse(f.scheduled())
        }
    }

    @Test fun detachAndPrimaryResumptionRecyclePostedPixelsAndStopPendingDecode() {
        for (detach in listOf(false, true)) Fixture().use { f ->
            val pixels = f.bitmap()
            (f.get("fallbackDecodeScheduled") as AtomicBoolean).set(true)
            assertEquals(true, f.call("postDecodedFallbackFrame", f.frame(1), pixels))
            f.admit(2)
            f.delta(3, 2)
            assertEquals(1, f.deferredDeltas())
            if (detach) f.view.hide()
            else (f.get("renderedFrameSeen") as AtomicBoolean).set(true)
            f.main.idle()

            assertTrue(pixels.isRecycled)
            assertFalse(f.scheduled())
            assertNull(f.pending())
            assertEquals(0, f.worker.queued)
            assertNull(f.get("fallbackBitmap"))
            assertEquals(0, f.deferredDeltas())
            assertEquals(0, f.deltasInFlight())
        }
    }

    @Test fun geometryAndStaleFrameRejectionsRecyclePixelsAndReleasePermit() {
        for (stale in listOf(false, true)) Fixture().use { f ->
            val pixels = f.bitmap()
            (f.get("fallbackDecodeScheduled") as AtomicBoolean).set(true)
            assertEquals(true, f.call("postDecodedFallbackFrame", f.frame(1), pixels))
            if (stale) f.set("fallbackCompositeFrameId", 2L)
            else f.set("geometry", RemoteGeometry(2, 40, 20))
            f.main.idle()

            assertTrue(pixels.isRecycled)
            assertFalse(f.scheduled())
            assertNull(f.get("fallbackBitmap"))
        }
    }

    @Test fun rejectedUiPostRecyclesWorkerPixelsAndReleasesProductionPermit() {
        Fixture().use { f ->
            val thread = HandlerThread("rejected-fallback-ui").apply { start() }
            val rejectedHandler = Handler(thread.looper)
            thread.quit()
            thread.join(5_000)
            assertFalse(thread.isAlive)
            f.set("mainHandler", rejectedHandler)

            val pixels = f.bitmap()
            assertEquals(false, f.call("postDecodedFallbackFrame", f.frame(1), pixels))
            assertTrue(pixels.isRecycled)

            f.admit(1)
            f.worker.runNext()
            assertFalse("The real decode path releases a rejected UI handoff", f.scheduled())
            assertNull(f.get("fallbackBitmap"))
            assertNull(f.pending())
        }
    }

    @Test fun rejectedExecutorDoesNotStrandTheDecodePermit() {
        Fixture().use { f ->
            f.worker.shutdown()
            f.admit(1)
            assertFalse(f.scheduled())
            assertEquals(0, f.worker.queued)
            assertNull(f.get("fallbackBitmap"))
        }
    }
}
