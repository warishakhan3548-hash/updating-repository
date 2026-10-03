package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertSame
import org.junit.Assert.assertEquals
import org.junit.Test
import org.webrtc.VideoTrack

class ControllerDeltaRoutingTest {
    @Test fun serviceRuntimeForwardsDeltaFramesInsteadOfSilentlyDroppingThem() {
        var received: FallbackDeltaFrame? = null
        var recoveries = 0
        val listener = object : ControllerWebRtcSession.Listener {
            override fun onLive(geometry: RemoteGeometry) = Unit
            override fun onConnectivityChanged(connected: Boolean) = Unit
            override fun onRemoteVideoTrack(track: VideoTrack) = Unit
            override fun onCommandResult(sequence: Long, applied: Boolean) = Unit
            override fun onRecoverableError(error: Throwable) = Unit
            override fun onTerminalError(error: Throwable) = Unit
            override fun onFallbackDeltaFrame(frame: FallbackDeltaFrame) { received = frame }
            override fun onPrimaryVideoRecoveryStarted() { recoveries++ }
        }
        val frame = FallbackDeltaFrame(2, 1, 80, 160, 0, 0, 0, emptyList())
        ControllerConnectionRuntime.setOwnerListener(listener)
        try {
            ControllerConnectionRuntime.runtimeListener.onFallbackDeltaFrame(frame)
            assertSame(frame, received)
            ControllerConnectionRuntime.runtimeListener.onPrimaryVideoRecoveryStarted()
            assertEquals("A later stall must re-arm the viewer's render confirmation", 1, recoveries)
        } finally { ControllerConnectionRuntime.setOwnerListener(null) }
    }
}
