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
@Config(sdk = [26])
class AarisRealtimeVideoEncoderFactoryTest {
    @Test
    fun encoderConfigurationGetsRealtimeSchedulingHints() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 720, 1280)

        AarisRealtimeVideoEncoderFactory.applyRealtimeHints(
            format,
            MediaCodec.CONFIGURE_FLAG_ENCODE
        )

        assertEquals(0, format.getInteger(MediaFormat.KEY_PRIORITY))
        assertEquals(1, format.getInteger(MediaFormat.KEY_LATENCY))
    }

    @Test
    fun decoderConfigurationIsNeverModified() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 720, 1280)

        AarisRealtimeVideoEncoderFactory.applyRealtimeHints(format, 0)

        assertFalse(format.containsKey(MediaFormat.KEY_PRIORITY))
        assertFalse(format.containsKey(MediaFormat.KEY_LATENCY))
    }
}
