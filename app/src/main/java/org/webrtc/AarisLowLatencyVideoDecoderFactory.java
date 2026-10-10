package org.webrtc;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecInfo.CodecCapabilities;
import android.media.MediaCodecList;
import android.media.MediaCrypto;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.view.Surface;
import androidx.annotation.Nullable;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.LinkedHashSet;

/**
 * A WebRTC-compatible decoder factory that preserves the stock hardware-first
 * + software-fallback behavior while enabling Android's official low-latency
 * MediaCodec mode on hardware decoders that explicitly advertise support.
 *
 * <p>This class intentionally lives in org.webrtc because the pinned WebRTC
 * Android SDK keeps AndroidVideoDecoder and MediaCodecWrapper package-private.
 * Keeping the integration at the codec-construction seam avoids reflection and
 * avoids a second decode/render queue.</p>
 */
public final class AarisLowLatencyVideoDecoderFactory implements VideoDecoderFactory {
  private final VideoDecoderFactory hardwareFactory;
  private final VideoDecoderFactory softwareFactory = new SoftwareVideoDecoderFactory();
  private final @Nullable VideoDecoderFactory platformSoftwareFactory;

  public AarisLowLatencyVideoDecoderFactory(@Nullable EglBase.Context eglContext) {
    hardwareFactory = new LowLatencyHardwareVideoDecoderFactory(eglContext);
    platformSoftwareFactory = new PlatformSoftwareVideoDecoderFactory(eglContext);
  }

  @Override
  public @Nullable VideoDecoder createDecoder(VideoCodecInfo codecInfo) {
    VideoDecoder softwareDecoder = softwareFactory.createDecoder(codecInfo);
    VideoDecoder hardwareDecoder = hardwareFactory.createDecoder(codecInfo);

    if (softwareDecoder == null && platformSoftwareFactory != null) {
      softwareDecoder = platformSoftwareFactory.createDecoder(codecInfo);
    }

    if (hardwareDecoder != null && softwareDecoder != null) {
      return new VideoDecoderFallback(
          /* fallback= */ softwareDecoder,
          /* primary= */ hardwareDecoder);
    }
    return hardwareDecoder != null ? hardwareDecoder : softwareDecoder;
  }

  @Override
  public VideoCodecInfo[] getSupportedCodecs() {
    LinkedHashSet<VideoCodecInfo> codecs = new LinkedHashSet<>();
    codecs.addAll(Arrays.asList(softwareFactory.getSupportedCodecs()));
    codecs.addAll(Arrays.asList(hardwareFactory.getSupportedCodecs()));
    if (platformSoftwareFactory != null) {
      codecs.addAll(Arrays.asList(platformSoftwareFactory.getSupportedCodecs()));
    }
    return codecs.toArray(new VideoCodecInfo[0]);
  }

  /**
   * Hardware factory matching WebRTC's normal Android hardware selection, but
   * constructing AndroidVideoDecoder with our capability-gated wrapper factory.
   */
  private static final class LowLatencyHardwareVideoDecoderFactory
      implements VideoDecoderFactory {
    private final @Nullable EglBase.Context sharedContext;
    private final VideoDecoderFactory supportedCodecsDelegate;

    LowLatencyHardwareVideoDecoderFactory(@Nullable EglBase.Context sharedContext) {
      this.sharedContext = sharedContext;
      this.supportedCodecsDelegate = new HardwareVideoDecoderFactory(sharedContext);
    }

    @Override
    public @Nullable VideoDecoder createDecoder(VideoCodecInfo codecInfo) {
      final VideoCodecMimeType type;
      try {
        type = VideoCodecMimeType.valueOf(codecInfo.getName());
      } catch (IllegalArgumentException unsupported) {
        return null;
      }

      MediaCodecInfo mediaCodecInfo = findHardwareDecoder(type);
      if (mediaCodecInfo == null) {
        return null;
      }

      CodecCapabilities capabilities;
      try {
        capabilities = mediaCodecInfo.getCapabilitiesForType(type.mimeType());
      } catch (RuntimeException capabilityFailure) {
        Logging.w(
            TAG,
            "Capability query failed for " + mediaCodecInfo.getName() + "; using normal fallback");
        return null;
      }

      Integer colorFormat =
          MediaCodecUtils.selectColorFormat(
              MediaCodecUtils.DECODER_COLOR_FORMATS,
              capabilities);
      if (colorFormat == null) {
        return null;
      }

      boolean lowLatencySupported =
          LowLatencyCapability.isSupported(capabilities);

      return new AndroidVideoDecoder(
          new LowLatencyMediaCodecWrapperFactory(
              type.mimeType(),
              lowLatencySupported),
          mediaCodecInfo.getName(),
          type,
          colorFormat,
          sharedContext);
    }

    @Override
    public VideoCodecInfo[] getSupportedCodecs() {
      // Preserve WebRTC's exact published codec/profile ordering and fmtp.
      return supportedCodecsDelegate.getSupportedCodecs();
    }

    private @Nullable MediaCodecInfo findHardwareDecoder(VideoCodecMimeType type) {
      MediaCodecList codecList =
          new MediaCodecList(MediaCodecList.ALL_CODECS);
      MediaCodecInfo firstCompatible = null;

      for (MediaCodecInfo info : codecList.getCodecInfos()) {
        if (info == null || info.isEncoder()) {
          continue;
        }
        if (!MediaCodecUtils.isHardwareAccelerated(info)) {
          continue;
        }
        if (!MediaCodecUtils.codecSupportsType(info, type)) {
          continue;
        }

        try {
          CodecCapabilities capabilities =
              info.getCapabilitiesForType(type.mimeType());
          if (MediaCodecUtils.selectColorFormat(
                  MediaCodecUtils.DECODER_COLOR_FORMATS,
                  capabilities)
              == null) {
            continue;
          }

          if (firstCompatible == null) {
            firstCompatible = info;
          }

          /*
           * Do not assume MediaCodecList order is latency-optimal. Some devices
           * expose a generic C2/OMX decoder first and a dedicated low-latency
           * decoder later. Prefer the first compatible decoder that explicitly
           * advertises Android's FEATURE_LowLatency; if none does, preserve the
           * normal first-compatible WebRTC behavior.
           */
          if (LowLatencyCapability.isSupported(capabilities)) {
            return info;
          }
        } catch (RuntimeException ignored) {
          // Broken vendor entries are skipped exactly like an unavailable codec.
        }
      }
      return firstCompatible;
    }
  }

  private static final class LowLatencyCapability {
    private LowLatencyCapability() {}

    static boolean isSupported(CodecCapabilities capabilities) {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
        return false;
      }
      return Api30.isSupported(capabilities);
    }

    private static final class Api30 {
      private Api30() {}

      static boolean isSupported(CodecCapabilities capabilities) {
        try {
          return capabilities.isFeatureSupported(
              CodecCapabilities.FEATURE_LowLatency);
        } catch (RuntimeException vendorFailure) {
          return false;
        }
      }

      static void enable(MediaFormat format) {
        format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
      }
    }
  }

  /**
   * Creates the exact MediaCodec requested by WebRTC. The low-latency bit is
   * immutable for this decoder instance and is decided from that codec's
   * advertised capability before AndroidVideoDecoder starts.
   */
  private static final class LowLatencyMediaCodecWrapperFactory
      implements MediaCodecWrapperFactory {
    private final String mimeType;
    private final boolean lowLatencySupported;

    LowLatencyMediaCodecWrapperFactory(
        String mimeType,
        boolean lowLatencySupported) {
      this.mimeType = mimeType;
      this.lowLatencySupported = lowLatencySupported;
    }

    @Override
    public MediaCodecWrapper createByCodecName(String name)
        throws IOException {
      return new LowLatencyMediaCodecWrapper(
          MediaCodec.createByCodecName(name),
          mimeType,
          lowLatencySupported);
    }
  }

  private static final class LowLatencyMediaCodecWrapper
      implements MediaCodecWrapper {
    private final MediaCodec codec;
    private final String mimeType;
    private final boolean lowLatencySupported;

    LowLatencyMediaCodecWrapper(
        MediaCodec codec,
        String mimeType,
        boolean lowLatencySupported) {
      this.codec = codec;
      this.mimeType = mimeType;
      this.lowLatencySupported = lowLatencySupported;
    }

    @Override
    public void configure(
        MediaFormat format,
        Surface surface,
        MediaCrypto crypto,
        int flags) {
      if (
          flags == 0 &&
          lowLatencySupported &&
          Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
      ) {
        LowLatencyCapability.Api30.enable(format);
        Logging.d(
            TAG,
            "Android low-latency decode enabled for "
                + codec.getName()
                + " "
                + mimeType);
      }
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
      codec.queueInputBuffer(
          index,
          offset,
          size,
          presentationTimeUs,
          flags);
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

  private static final String TAG = "AarisLowLatencyDecoder";
}
