package com.aaris.remoteassist.webrtc

import android.content.Context
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
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
            val encoderFactory = DefaultVideoEncoderFactory(
                eglBase.eglBaseContext,
                true,
                true
            )
            val decoderFactory = DefaultVideoDecoderFactory(
                eglBase.eglBaseContext
            )

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
