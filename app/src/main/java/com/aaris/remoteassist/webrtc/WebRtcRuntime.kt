package com.aaris.remoteassist.webrtc

import android.content.Context
import org.webrtc.AarisLowLatencyVideoDecoderFactory
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

    fun hardwareScreenEncoders(context: Context): Set<String> {
        initialize(context)
        return hardwareEncoders
    }

    fun hardwareScreenDecoders(context: Context): Set<String> {
        initialize(context)
        return hardwareDecoders
    }

    fun initialize(context: Context) {
        if (initialized) return

        synchronized(lock) {
            if (initialized) return

            val appContext = context.applicationContext
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions
                    .builder(appContext)
                    /*
                     * Enable native timestamp-based smoothing with a 10 ms
                     * floor and a best-effort 500 ms ceiling. The ceiling is
                     * recovery headroom, not a fixed half-second delay. Keep
                     * packet repair and timed decode inside libwebrtc rather
                     * than buffering decoded frames in the Android viewer.
                     */
                    .setFieldTrials(RealtimeMediaPolicy.FIELD_TRIALS)
                    .setEnableInternalTracer(false)
                    .createInitializationOptions()
            )

            val eglBase = EglBase.create()
            /*
             * Prefer Android's hardware codec path for screen sharing, but do
             * not make hardware success a correctness requirement.
             *
             * DefaultVideoEncoderFactory plus AarisLowLatencyVideoDecoderFactory
             * preserve hardware-first decoding with software fallback. On
             * Android 11+ the decoder factory enables MediaCodec's official
             * low-latency mode only when the selected hardware codec explicitly
             * advertises FEATURE_LowLatency; unsupported codecs and older
             * devices keep WebRTC's normal behavior.
             *
             * The same EGL context is shared by capture, codecs and rendering
             * so texture-backed frames stay on the GPU path without adding a
             * decoded-frame queue or CPU copy.
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
                AarisLowLatencyVideoDecoderFactory(
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
