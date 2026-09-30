package com.aaris.remoteassist.webrtc

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.aaris.remoteassist.control.ControlPacket
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
        fun onError(error: Throwable)
    }

    private val appContext = context.applicationContext
    private val closed = AtomicBoolean(false)
    private val sequence = AtomicLong(0L)
    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    private var leaseSecret: Long? = null

    @Volatile
    private var geometry: RemoteGeometry? = null

    private val signaling = FirebaseSignalingClient(
        sessionId = sessionId,
        role = PeerRole.CONTROLLER
    )

    private val peer = WebRtcPeer(
        context = appContext,
        role = PeerRole.CONTROLLER,
        signaling = signaling,
        listener = this
    )

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
        peer.start()
    }

    fun remoteGeometry(): RemoteGeometry? = geometry

    fun sendTap(nx: Float, ny: Float): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

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
        durationMs: Int
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

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
        durationMs: Int
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

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

    override fun onPeerConnected() {
        listener.onConnectivityChanged(true)
    }

    override fun onPeerDisconnected() {
        listener.onConnectivityChanged(false)
    }

    override fun onControlChannelOpen() = Unit

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
        if (!closed.compareAndSet(false, true)) return

        handler.removeCallbacks(heartbeat)
        runCatching {
            peer.sendControl(
                ControlProtocol.encode(
                    ControlPacket.Disconnect
                )
            )
        }
        runCatching { peer.close() }

        leaseSecret = null
        geometry = null
    }

    companion object {
        private const val HEARTBEAT_MS = 5_000L
        private const val MAX_REMOTE_TEXT_CHARS = 500
    }
}
