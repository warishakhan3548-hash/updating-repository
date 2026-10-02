package com.aaris.remoteassist.webrtc

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlPathPoint
import com.aaris.remoteassist.control.ControlProtocol
import org.webrtc.VideoTrack
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

data class RemoteGeometry(
    val generation: Int,
    val widthPx: Int,
    val heightPx: Int
)

class ControllerWebRtcSession(
    context: Context,
    private val sessionId: String,
    private val listener: Listener
) : Closeable, WebRtcPeer.Listener {
    interface Listener {
        fun onLive(geometry: RemoteGeometry)
        fun onConnectivityChanged(connected: Boolean)
        fun onRemoteVideoTrack(track: VideoTrack)
        fun onCommandResult(sequence: Long, applied: Boolean)
        fun onError(error: Throwable)
    }

    private val appContext = context.applicationContext
    private val closed = AtomicBoolean(false)
    private val sequence = AtomicLong(0L)
    private val handler = Handler(Looper.getMainLooper())
    private val transport = ControlTransportTracker()

    @Volatile
    private var leaseSecret: Long? = null

    @Volatile
    private var geometry: RemoteGeometry? = null

    private val signaling = CloudflareSignalingClient(
        context = appContext,
        sessionId = sessionId,
        role = PeerRole.CONTROLLER
    )

    private val peer = WebRtcPeer(
        context = appContext,
        sessionId = sessionId,
        role = PeerRole.CONTROLLER,
        signaling = signaling,
        listener = this
    )

    private val helloWatchdog = Runnable {
        if (!closed.get() && leaseSecret == null) {
            listener.onError(
                IllegalStateException(
                    "Remote control handshake timed out"
                )
            )
        }
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            if (closed.get()) return

            val lease = leaseSecret
            if (lease != null) {
                peer.sendControl(
                    ControlProtocol.encode(
                        ControlPacket.Heartbeat(lease)
                    )
                )
            }

            handler.postDelayed(this, HEARTBEAT_MS)
        }
    }

    fun start() {
        check(!closed.get())
        handler.removeCallbacks(helloWatchdog)
        handler.postDelayed(
            helloWatchdog,
            HELLO_TIMEOUT_MS
        )
        peer.start()
    }

    fun remoteGeometry(): RemoteGeometry? = geometry

    fun requestMediaRecovery(): Boolean {
        if (closed.get()) return false
        return peer.requestRemoteRecovery()
    }

    fun sendTap(
        nx: Float,
        ny: Float,
        expectedGeneration: Int? = null
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Tap(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet(),
                    nx = nx,
                    ny = ny
                )
            )
        )
    }

    fun sendLongPress(
        nx: Float,
        ny: Float,
        durationMs: Int,
        expectedGeneration: Int? = null
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.LongPress(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet(),
                    nx = nx,
                    ny = ny,
                    durationMs = durationMs
                )
            )
        )
    }

    fun sendSwipe(
        fromNx: Float,
        fromNy: Float,
        toNx: Float,
        toNy: Float,
        durationMs: Int,
        expectedGeneration: Int? = null
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Swipe(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet(),
                    fromNx = fromNx,
                    fromNy = fromNy,
                    toNx = toNx,
                    toNy = toNy,
                    durationMs = durationMs
                )
            )
        )
    }

    fun sendGesturePath(
        points: List<Pair<Float, Float>>,
        durationMs: Int,
        expectedGeneration: Int
    ): Boolean {
        if (points.size !in 2..MAX_GESTURE_PATH_POINTS) return false

        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false
        val controlPoints = points.map { (nx, ny) ->
            if (!nx.isFinite() || !ny.isFinite()) return false
            ControlPathPoint(
                nx = nx.coerceIn(0f, 1f),
                ny = ny.coerceIn(0f, 1f)
            )
        }

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.GesturePath(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet(),
                    points = controlPoints,
                    durationMs = durationMs
                )
            )
        )
    }

    fun sendTwoFingerGesture(
        firstFromNx: Float,
        firstFromNy: Float,
        firstToNx: Float,
        firstToNy: Float,
        secondFromNx: Float,
        secondFromNy: Float,
        secondToNx: Float,
        secondToNy: Float,
        durationMs: Int,
        expectedGeneration: Int? = null
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.TwoFinger(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet(),
                    firstFromNx = firstFromNx,
                    firstFromNy = firstFromNy,
                    firstToNx = firstToNx,
                    firstToNy = firstToNy,
                    secondFromNx = secondFromNx,
                    secondFromNy = secondFromNy,
                    secondToNx = secondToNx,
                    secondToNy = secondToNy,
                    durationMs = durationMs
                )
            )
        )
    }

    fun sendBack(): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Back(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet()
                )
            )
        )
    }

    fun sendHome(): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Home(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet()
                )
            )
        )
    }

    fun sendRecents(): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Recents(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet()
                )
            )
        )
    }

    fun sendText(text: String): Boolean {
        val safeText = text.take(MAX_REMOTE_TEXT_CHARS)
        if (safeText.isEmpty()) return false
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Text(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = sequence.incrementAndGet(),
                    text = safeText
                )
            )
        )
    }

    private fun currentGeometry(
        expectedGeneration: Int?
    ): RemoteGeometry? {
        val current = geometry ?: return null
        if (
            expectedGeneration != null &&
            current.generation != expectedGeneration
        ) {
            return null
        }
        return current
    }

    override fun onPeerConnected() {
        transport.onPeerConnected()
            ?.let(listener::onConnectivityChanged)
    }

    override fun onPeerDisconnected() {
        transport.onPeerDisconnected()
            ?.let(listener::onConnectivityChanged)
    }

    override fun onControlChannelOpen() {
        transport.onControlChannelOpen()
            ?.let(listener::onConnectivityChanged)
    }

    override fun onControlChannelClosed() {
        transport.onControlChannelClosed()
            ?.let(listener::onConnectivityChanged)
    }

    override fun onControlMessage(bytes: ByteArray) {
        when (val packet = ControlProtocol.decode(bytes)) {
            is ControlPacket.Hello -> {
                if (
                    packet.widthPx <= 0 ||
                    packet.heightPx <= 0 ||
                    packet.generation < 0
                ) {
                    return
                }

                leaseSecret = packet.leaseSecret
                handler.removeCallbacks(helloWatchdog)
                val geometry = RemoteGeometry(
                    generation = packet.generation,
                    widthPx = packet.widthPx,
                    heightPx = packet.heightPx
                )
                this.geometry = geometry

                handler.removeCallbacks(heartbeat)
                handler.post(heartbeat)

                listener.onLive(geometry)
            }

            is ControlPacket.CommandResult ->
                listener.onCommandResult(
                    sequence = packet.sequence,
                    applied = packet.applied
                )

            else -> Unit
        }
    }

    override fun onRemoteVideoTrack(track: VideoTrack) {
        listener.onRemoteVideoTrack(track)
    }

    override fun onError(error: Throwable) {
        listener.onError(error)
    }

    override fun close() {
        close(notifyRemote = true)
    }

    fun close(notifyRemote: Boolean) {
        if (!closed.compareAndSet(false, true)) return

        handler.removeCallbacks(helloWatchdog)
        handler.removeCallbacks(heartbeat)
        if (notifyRemote) {
            runCatching {
                peer.sendControl(
                    ControlProtocol.encode(
                        ControlPacket.Disconnect
                    )
                )
            }
        }
        runCatching { peer.close() }

        leaseSecret = null
        geometry = null
    }

    companion object {
        private const val HEARTBEAT_MS = 5_000L
        private const val HELLO_TIMEOUT_MS = 90_000L
        private const val MAX_REMOTE_TEXT_CHARS = 500
        private const val MAX_GESTURE_PATH_POINTS = 96
    }
}
