package com.aaris.remoteassist.webrtc

import android.content.Context
import org.webrtc.SoftwareVideoDecoderFactory
import org.webrtc.SoftwareVideoEncoderFactory
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
             * Screen sharing reliability beats peak hardware throughput here.
             * Some Android vendor MediaCodec implementations accept an RTC
             * encoder session but then emit no usable frames. Meta has publicly
             * described the same class of mobile RTC problem and uses software
             * codecs when hardware behavior is unsuitable.
             *
             * Aaris therefore starts with libwebrtc software codecs (VP8 first)
             * for deterministic cross-device behavior. The capture profile is
             * intentionally capped so this remains practical on low-end phones.
             */
            val encoderFactory = SoftwareVideoEncoderFactory()
            val decoderFactory = SoftwareVideoDecoderFactory()

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
