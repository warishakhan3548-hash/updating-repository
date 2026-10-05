package com.aaris.remoteassist.webrtc

import android.content.Context
import com.aaris.remoteassist.webrtc.advanced.CodecTelemetryRegistry
import com.aaris.remoteassist.webrtc.advanced.DecoderTelemetry
import com.aaris.remoteassist.webrtc.advanced.EncoderTelemetry
import com.aaris.remoteassist.webrtc.advanced.TelemetryDecoderFactory
import com.aaris.remoteassist.webrtc.advanced.TelemetryEncoderFactory
import org.webrtc.EglBase
import org.webrtc.HardwareVideoDecoderFactory
import org.webrtc.HardwareVideoEncoderFactory
import org.webrtc.PeerConnectionFactory
import org.webrtc.PlatformSoftwareVideoDecoderFactory
import org.webrtc.SoftwareVideoDecoderFactory
import org.webrtc.SoftwareVideoEncoderFactory

object WebRtcRuntime {
    private val lock = Any()

    @Volatile
    private var initialized = false
    private var nativeInitialized = false

    @Volatile
    private var eglBaseInternal: EglBase? = null

    @Volatile
    private var factoryInternal: PeerConnectionFactory? = null

    @Volatile
    private var hardwareEncoders: Set<String> = emptySet()

    @Volatile
    private var hardwareDecoders: Set<String> = emptySet()

    private val codecTelemetry = CodecTelemetryRegistry()

    fun preferredScreenCodec(context: Context, sender: Boolean): String {
        initialize(context)
        return ScreenCodecPolicy.preferred(
            if (sender) hardwareEncoders else hardwareDecoders
        )
    }

    fun initialize(context: Context) {
        if (initialized) return

        synchronized(lock) {
            if (initialized) return

            val eglBase = captureEglBase(context)

            /*
             * Keep the same hardware-first/software-fallback behaviour as
             * DefaultVideoEncoderFactory/DefaultVideoDecoderFactory, but wrap
             * Java MediaCodec implementations so Aaris can observe per-frame
             * p50/p95 encode/decode latency and instantaneous encoded-frame
             * size. Native software codecs still bypass Java exactly as before.
             *
             * Decoder composition intentionally preserves the platform-software
             * MediaCodec fallback that DefaultVideoDecoderFactory supplies when
             * the built-in native software factory cannot service a codec.
             */
            val hardwareEncoderFactory =
                HardwareVideoEncoderFactory(
                    eglBase.eglBaseContext,
                    true,
                    false
                )
            val softwareEncoderFactory = SoftwareVideoEncoderFactory()
            val encoderFactory =
                TelemetryEncoderFactory(
                    hardware = hardwareEncoderFactory,
                    software = softwareEncoderFactory,
                    registry = codecTelemetry
                )

            val hardwareDecoderFactory =
                HardwareVideoDecoderFactory(eglBase.eglBaseContext)
            val softwareDecoderFactory = SoftwareVideoDecoderFactory()
            val platformSoftwareDecoderFactory =
                PlatformSoftwareVideoDecoderFactory(
                    eglBase.eglBaseContext
                )
            val decoderFactory =
                TelemetryDecoderFactory(
                    hardware = hardwareDecoderFactory,
                    software = softwareDecoderFactory,
                    platformSoftware = platformSoftwareDecoderFactory,
                    registry = codecTelemetry
                )

            hardwareEncoders =
                runCatching {
                    hardwareEncoderFactory.supportedCodecs
                        .map { it.name.uppercase() }
                        .toSet()
                }.getOrDefault(emptySet())
            hardwareDecoders =
                runCatching {
                    hardwareDecoderFactory.supportedCodecs
                        .map { it.name.uppercase() }
                        .toSet()
                }.getOrDefault(emptySet())

            val peerFactory =
                PeerConnectionFactory.builder()
                    .setVideoEncoderFactory(encoderFactory)
                    .setVideoDecoderFactory(decoderFactory)
                    .createPeerConnectionFactory()

            eglBaseInternal = eglBase
            factoryInternal = peerFactory
            initialized = true
        }
    }

    fun encoderTelemetry(codec: String? = null): EncoderTelemetry? =
        codecTelemetry.encoder(codec)

    fun latestEncoderTelemetry(): EncoderTelemetry? =
        codecTelemetry.latestEncoder()

    fun decoderTelemetry(codec: String? = null): DecoderTelemetry? =
        codecTelemetry.decoder(codec)

    fun eglBase(context: Context): EglBase {
        initialize(context)
        return checkNotNull(eglBaseInternal)
    }

    /** Snapshot-only AI capture needs EGL/native buffers, not a peer/codec factory. */
    fun captureEglBase(context: Context): EglBase = synchronized(lock) {
        if (!nativeInitialized) {
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(context.applicationContext)
                    .setEnableInternalTracer(false).createInitializationOptions()
            )
            nativeInitialized = true
        }
        eglBaseInternal ?: EglBase.create().also { eglBaseInternal = it }
    }

    fun factory(context: Context): PeerConnectionFactory {
        initialize(context)
        return checkNotNull(factoryInternal)
    }
}
