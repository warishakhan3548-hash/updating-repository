package org.webrtc

import android.media.MediaCodec
import android.media.MediaFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class AarisLowLatencyVideoDecoderFactoryTest {
    @Test
    @Config(sdk = [26])
    fun decoderGetsRealtimePriorityBeforeLowLatencyApi() {
        val format =
            MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                720,
                1280
            )

        AarisLowLatencyVideoDecoderFactory.applyRealtimeHints(
            format,
            0,
            true
        )

        assertEquals(0, format.getInteger(MediaFormat.KEY_PRIORITY))
        assertFalse(format.containsKey(MediaFormat.KEY_LOW_LATENCY))
    }

    @Test
    @Config(sdk = [30])
    fun capableDecoderGetsRealtimePriorityAndLowLatencyMode() {
        val format =
            MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                720,
                1280
            )

        AarisLowLatencyVideoDecoderFactory.applyRealtimeHints(
            format,
            0,
            true
        )

        assertEquals(0, format.getInteger(MediaFormat.KEY_PRIORITY))
        assertEquals(1, format.getInteger(MediaFormat.KEY_LOW_LATENCY))
    }

    @Test
    @Config(sdk = [30])
    fun decoderWithoutLowLatencyFeatureStillGetsRealtimePriority() {
        val format =
            MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                720,
                1280
            )

        AarisLowLatencyVideoDecoderFactory.applyRealtimeHints(
            format,
            0,
            false
        )

        assertEquals(0, format.getInteger(MediaFormat.KEY_PRIORITY))
        assertFalse(format.containsKey(MediaFormat.KEY_LOW_LATENCY))
    }

    @Test
    @Config(sdk = [30])
    fun encoderConfigurationIsNeverModifiedByDecoderHints() {
        val format =
            MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                720,
                1280
            )

        AarisLowLatencyVideoDecoderFactory.applyRealtimeHints(
            format,
            MediaCodec.CONFIGURE_FLAG_ENCODE,
            true
        )

        assertFalse(format.containsKey(MediaFormat.KEY_PRIORITY))
        assertFalse(format.containsKey(MediaFormat.KEY_LOW_LATENCY))
    }
}
