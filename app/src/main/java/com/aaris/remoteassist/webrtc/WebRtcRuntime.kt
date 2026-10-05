package com.aaris.remoteassist.webrtc

import android.content.Context
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.HardwareVideoEncoderFactory
import org.webrtc.HardwareVideoDecoderFactory
import org.webrtc.EglBase
import org.webrtc.PeerConnectionFactory

object WebRtcRuntime {
    private val lock = Any()

    @Volatile
    private var initialized = false

    @Volatile
    private var eglBaseInternal: EglBase? = null

    @Volatile
    private var factoryInternal: PeerConnectionFactory? = null
    @Volatile private var hardwareEncoders: Set<String> = emptySet()
    @Volatile private var hardwareDecoders: Set<String> = emptySet()

    fun preferredScreenCodec(context: Context, sender: Boolean): String {
        initialize(context)
        return ScreenCodecPolicy.preferred(if (sender) hardwareEncoders else hardwareDecoders)
    }

    fun initialize(context: Context) {
        if (initialized) return

        synchronized(lock) {
            if (initialized) return

            val appContext = context.applicationContext
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions
                    .builder(appContext)
                    .setEnableInternalTracer(false)
                    .createInitializationOptions()
            )

            val eglBase = EglBase.create()
            /*
             * Prefer Android's hardware codec path for screen sharing, but do
             * not make hardware success a correctness requirement.
             *
             * DefaultVideoEncoderFactory/DefaultVideoDecoderFactory compose
             * hardware and software implementations and fall back when a
             * vendor MediaCodec cannot service the requested codec/profile.
             * This keeps the deterministic cross-device safety net that Aaris
             * previously got from software-only VP8 while removing a major CPU
             * bottleneck on healthy devices. The same EGL context is shared by
             * capture, codecs and rendering so texture-backed frames can stay
             * on the GPU path instead of paying avoidable CPU copies.
             *
             * H264 high-profile remains disabled. Capability-based negotiation
             * can use hardware baseline H264; VP8 remains available. Intel VP8 acceleration
             * is harmless on ARM and useful for x86/ChromeOS-class devices.
             */
            val encoderFactory =
                DefaultVideoEncoderFactory(
                    eglBase.eglBaseContext,
                    true,
                    false
                )
            val decoderFactory =
                DefaultVideoDecoderFactory(
                    eglBase.eglBaseContext
                )
            hardwareEncoders = runCatching { HardwareVideoEncoderFactory(eglBase.eglBaseContext, true, false)
                .supportedCodecs.map { it.name.uppercase() }.toSet() }.getOrDefault(emptySet())
            hardwareDecoders = runCatching { HardwareVideoDecoderFactory(eglBase.eglBaseContext)
                .supportedCodecs.map { it.name.uppercase() }.toSet() }.getOrDefault(emptySet())

            val peerFactory = PeerConnectionFactory.builder()
                .setVideoEncoderFactory(encoderFactory)
                .setVideoDecoderFactory(decoderFactory)
                .createPeerConnectionFactory()

            eglBaseInternal = eglBase
            factoryInternal = peerFactory
            initialized = true
        }
    }

    fun eglBase(context: Context): EglBase {
        initialize(context)
        return checkNotNull(eglBaseInternal)
    }

    fun factory(context: Context): PeerConnectionFactory {
        initialize(context)
        return checkNotNull(factoryInternal)
    }
}
