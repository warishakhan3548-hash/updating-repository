package org.webrtc;

import static org.webrtc.MediaCodecUtils.EXYNOS_PREFIX;
import static org.webrtc.MediaCodecUtils.QCOM_PREFIX;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaCrypto;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.view.Surface;
import androidx.annotation.Nullable;
import java.io.IOException;
import java.nio.ByteBuffer;

/**
 * WebRTC's normal hardware-first encoder factory with Android realtime encoder
 * resource hints applied at the MediaCodec configuration seam.
 *
 * <p>The pinned WebRTC M150 {@link HardwareVideoEncoder} sets the intended
 * frame rate but does not set {@link MediaFormat#KEY_PRIORITY}. Android only
 * treats that frame-rate value as the desired realtime operating rate when
 * priority is {@code 0}. Under UI/GPU/thermal contention an otherwise capable
 * hardware encoder can therefore be planned as best-effort and emit frames in
 * bursts, which is visible as controller-side judder.</p>
 *
 * <p>This factory preserves WebRTC's codec allow-list, ordering, H.264 profile
 * checks, vendor bitrate adjusters, Qualcomm key-frame workaround and software
 * fallback. It changes only the MediaFormat passed to the already-selected
 * hardware encoder: realtime priority and a one-frame latency request. Both are
 * public Android API 26 contracts; unsupported latency hints are documented to
 * be ignored. No vendor option, reflection, queue or second encoder is added.</p>
 */
public final class AarisRealtimeVideoEncoderFactory implements VideoEncoderFactory {
  private final VideoEncoderFactory delegate;

  public AarisRealtimeVideoEncoderFactory(
      @Nullable EglBase.Context eglContext,
      boolean enableIntelVp8Encoder,
      boolean enableH264HighProfile) {
    delegate =
        new DefaultVideoEncoderFactory(
            new RealtimeHardwareVideoEncoderFactory(
                eglContext,
                enableIntelVp8Encoder,
                enableH264HighProfile));
  }

  @Override
  public @Nullable VideoEncoder createEncoder(VideoCodecInfo codecInfo) {
    return delegate.createEncoder(codecInfo);
  }

  @Override
  public VideoCodecInfo[] getSupportedCodecs() {
    return delegate.getSupportedCodecs();
  }

  /**
   * Keep stock codec discovery authoritative, then reconstruct only the
   * hardware H.264/VP8 encoder with a wrapped MediaCodec factory. If an OEM
   * exposes incomplete metadata, return WebRTC's original encoder unchanged.
   */
  private static final class RealtimeHardwareVideoEncoderFactory
      implements VideoEncoderFactory {
    private static final int PERIODIC_KEY_FRAME_INTERVAL_S = 3600;
    private static final int QCOM_VP8_KEY_FRAME_INTERVAL_ANDROID_L_MS = 15_000;
    private static final int QCOM_VP8_KEY_FRAME_INTERVAL_ANDROID_M_MS = 20_000;
    private static final int QCOM_VP8_KEY_FRAME_INTERVAL_ANDROID_N_MS = 15_000;

    private final HardwareVideoEncoderFactory stockFactory;
    private final @Nullable EglBase14.Context sharedContext;

    RealtimeHardwareVideoEncoderFactory(
        @Nullable EglBase.Context eglContext,
        boolean enableIntelVp8Encoder,
        boolean enableH264HighProfile) {
      stockFactory =
          new HardwareVideoEncoderFactory(
              eglContext,
              enableIntelVp8Encoder,
              enableH264HighProfile);
      sharedContext =
          eglContext instanceof EglBase14.Context
              ? (EglBase14.Context) eglContext
              : null;
    }

    @Override
    public @Nullable VideoEncoder createEncoder(VideoCodecInfo codecInfo) {
      final VideoEncoder stockEncoder;
      try {
        stockEncoder = stockFactory.createEncoder(codecInfo);
      } catch (RuntimeException unsupportedCodec) {
        return null;
      }
      if (stockEncoder == null) {
        return null;
      }

      final VideoCodecMimeType type;
      try {
        type = VideoCodecMimeType.valueOf(codecInfo.getName());
      } catch (IllegalArgumentException unsupportedCodec) {
        return stockEncoder;
      }

      // Aaris currently negotiates H.264/VP8 for the primary screen stream.
      // Leave every other hardware codec on WebRTC's exact stock path.
      if (type != VideoCodecMimeType.H264 && type != VideoCodecMimeType.VP8) {
        return stockEncoder;
      }

      final String codecName = stockEncoder.getImplementationName();
      final MediaCodecInfo codec = findCodecByName(codecName);
      if (codec == null) {
        return stockEncoder;
      }

      try {
        final MediaCodecInfo.CodecCapabilities capabilities =
            codec.getCapabilitiesForType(type.mimeType());
        final Integer surfaceColorFormat =
            MediaCodecUtils.selectColorFormat(
                MediaCodecUtils.TEXTURE_COLOR_FORMATS,
                capabilities);
        final Integer yuvColorFormat =
            MediaCodecUtils.selectColorFormat(
                MediaCodecUtils.ENCODER_COLOR_FORMATS,
                capabilities);
        if (yuvColorFormat == null) {
          return stockEncoder;
        }

        return new HardwareVideoEncoder(
            new RealtimeMediaCodecWrapperFactory(),
            codecName,
            type,
            surfaceColorFormat,
            yuvColorFormat,
            codecInfo.params,
            PERIODIC_KEY_FRAME_INTERVAL_S,
            forcedKeyFrameIntervalMs(type, codecName),
            bitrateAdjuster(type, codecName),
            sharedContext);
      } catch (RuntimeException incompleteVendorMetadata) {
        return stockEncoder;
      }
    }

    @Override
    public VideoCodecInfo[] getSupportedCodecs() {
      // Preserve WebRTC's exact profile/fmtp publication and preference order.
      return stockFactory.getSupportedCodecs();
    }

    private static @Nullable MediaCodecInfo findCodecByName(String codecName) {
      try {
        for (MediaCodecInfo codec :
            new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
          if (codec != null && codec.getName().equals(codecName)) {
            return codec;
          }
        }
      } catch (RuntimeException ignored) {
        // The already-created stock encoder remains the safe fallback.
      }
      return null;
    }

    private static int forcedKeyFrameIntervalMs(
        VideoCodecMimeType type,
        String codecName) {
      if (type != VideoCodecMimeType.VP8 || !codecName.startsWith(QCOM_PREFIX)) {
        return 0;
      }
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
        return QCOM_VP8_KEY_FRAME_INTERVAL_ANDROID_L_MS;
      }
      if (Build.VERSION.SDK_INT == Build.VERSION_CODES.M) {
        return QCOM_VP8_KEY_FRAME_INTERVAL_ANDROID_M_MS;
      }
      return QCOM_VP8_KEY_FRAME_INTERVAL_ANDROID_N_MS;
    }

    private static BitrateAdjuster bitrateAdjuster(
        VideoCodecMimeType type,
        String codecName) {
      if (codecName.startsWith(EXYNOS_PREFIX)) {
        return type == VideoCodecMimeType.VP8
            ? new DynamicBitrateAdjuster()
            : new FramerateBitrateAdjuster();
      }
      return new BaseBitrateAdjuster();
    }
  }

  static void applyRealtimeHints(MediaFormat format, int flags) {
    if ((flags & MediaCodec.CONFIGURE_FLAG_ENCODE) == 0) {
      return;
    }
    // minSdk is 26. Priority 0 tells Android resource planning that the
    // configured frame rate must be treated as realtime, not informational.
    format.setInteger(MediaFormat.KEY_PRIORITY, 0);
    // Public optional encoder hint: emit after at most one queued frame when
    // supported. Android specifies that unsupported encoders ignore this key.
    format.setInteger(MediaFormat.KEY_LATENCY, 1);
  }

  private static final class RealtimeMediaCodecWrapperFactory
      implements MediaCodecWrapperFactory {
    @Override
    public MediaCodecWrapper createByCodecName(String name) throws IOException {
      return new RealtimeMediaCodecWrapper(MediaCodec.createByCodecName(name));
    }
  }

  private static final class RealtimeMediaCodecWrapper
      implements MediaCodecWrapper {
    private final MediaCodec codec;

    RealtimeMediaCodecWrapper(MediaCodec codec) {
      this.codec = codec;
    }

    @Override
    public void configure(
        MediaFormat format,
        Surface surface,
        MediaCrypto crypto,
        int flags) {
      applyRealtimeHints(format, flags);
      codec.configure(format, surface, crypto, flags);
    }

    @Override
    public void start() {
      codec.start();
    }

    @Override
    public void flush() {
      codec.flush();
    }

    @Override
    public void stop() {
      codec.stop();
    }

    @Override
    public void release() {
      codec.release();
    }

    @Override
    public int dequeueInputBuffer(long timeoutUs) {
      return codec.dequeueInputBuffer(timeoutUs);
    }

    @Override
    public void queueInputBuffer(
        int index,
        int offset,
        int size,
        long presentationTimeUs,
        int flags) {
      codec.queueInputBuffer(index, offset, size, presentationTimeUs, flags);
    }

    @Override
    public int dequeueOutputBuffer(
        MediaCodec.BufferInfo info,
        long timeoutUs) {
      return codec.dequeueOutputBuffer(info, timeoutUs);
    }

    @Override
    public void releaseOutputBuffer(int index, boolean render) {
      codec.releaseOutputBuffer(index, render);
    }

    @Override
    public MediaFormat getInputFormat() {
      return codec.getInputFormat();
    }

    @Override
    public MediaFormat getOutputFormat() {
      return codec.getOutputFormat();
    }

    @Override
    public MediaFormat getOutputFormat(int index) {
      return codec.getOutputFormat(index);
    }

    @Override
    public ByteBuffer getInputBuffer(int index) {
      return codec.getInputBuffer(index);
    }

    @Override
    public ByteBuffer getOutputBuffer(int index) {
      return codec.getOutputBuffer(index);
    }

    @Override
    public Surface createInputSurface() {
      return codec.createInputSurface();
    }

    @Override
    public void setParameters(Bundle params) {
      codec.setParameters(params);
    }

    @Override
    public MediaCodecInfo getCodecInfo() {
      return codec.getCodecInfo();
    }
  }
}
