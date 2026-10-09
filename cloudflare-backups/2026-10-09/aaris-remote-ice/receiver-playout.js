// Serialized into the browser module by browserResponse. Keep dependencies local.
export function createAdaptivePlayoutPolicy() {
  const ladder = [100, 150, 250, 350, 500];
  const valid = value => Number.isFinite(value) && value >= 0 ? value : null;
  let level = 0, pressureWindows = 0, cleanSinceMs = null;
  let lastChangeMs = -Infinity, lastSampleMs = null;
  let drainAllowanceMs = null, drainUntilMs = -Infinity;
  let presentation = null;
  const targetMs = () => ladder[level];

  // Never subtract WebRTC's entire adaptive target: growth ABOVE the accepted
  // application preference remains visible to the sender's freshness governors.
  function pressureDelayMs(actualMs, measuredTargetMs, acceptedTargetMs) {
    const actual = valid(actualMs), measured = valid(measuredTargetMs);
    const accepted = valid(acceptedTargetMs);
    if (actual == null && measured == null) return null;
    const allowance = accepted == null ? 0 :
      measured == null ? accepted : Math.min(accepted, measured);
    return Math.max(0, Math.max(actual ?? 0, measured ?? 0) - allowance);
  }

  function observe(sample = {}) {
    const now = valid(sample.nowMs), ms = valid(sample.intervalMs);
    const oldTarget = targetMs();
    const accepted = valid(sample.acceptedTargetMs);
    // A planned downshift takes time to drain. Briefly retain the OLD accepted
    // allowance, never anything above it, then expose any remaining backlog.
    const accountedBudget = now != null && now < drainUntilMs && accepted === oldTarget &&
      accepted != null && drainAllowanceMs != null && accepted < drainAllowanceMs
      ? drainAllowanceMs : accepted;
    const excessDelayMs = pressureDelayMs(sample.actualDelayMs, sample.targetDelayMs, accountedBudget);
    const result = (changed = false, reason = null) => ({
      targetMs: targetMs(), changed, reason, excessDelayMs, pressureWindows
    });
    if (now == null || ms == null || ms < 500 || ms > 6000 ||
        (lastSampleMs != null && now <= lastSampleMs)) return result();
    // Hidden tabs, reconnects and missing samples do not count as clean time.
    if (lastSampleMs != null && now - lastSampleMs > 6000) {
      pressureWindows = 0; cleanSinceMs = null;
    }
    lastSampleMs = now;
    const frames = valid(sample.frames), floor = valid(sample.minimumDelayMs);
    const decode = valid(sample.decodeMs), dropped = valid(sample.dropped), freezes = valid(sample.freezes);
    const active = frames != null && frames >= 5;
    const headroom = floor == null ? null : oldTarget - floor;
    const framePeriod = 1000 / Math.max(24, (frames ?? 0) * 1000 / ms);
    const decoderHealthy = decode != null && decode < framePeriod * 0.8;
    const queueHealthy = excessDelayMs != null && excessDelayMs <= 80;
    // Increasing delay only helps jitter starvation. A slow decoder, growing
    // queue, or unrelated dropped frames must not buy themselves more latency.
    const jitterPressure = active && accepted != null && decoderHealthy && queueHealthy &&
      headroom != null && headroom <= 35;
    pressureWindows = jitterPressure ? Math.min(6, pressureWindows + ((freezes ?? 0) > 0 ? 2 : 1)) : 0;
    if (level < ladder.length - 1 && pressureWindows >= 2 && now - lastChangeMs >= 4000) {
      level++; lastChangeMs = now; pressureWindows = 0; cleanSinceMs = null;
      return result(true, 'jitter-headroom');
    }
    const lowerTarget = ladder[Math.max(0, level - 1)];
    const clean = active && accepted != null && decoderHealthy &&
      dropped === 0 && freezes === 0 && excessDelayMs != null && excessDelayMs <= 30 &&
      floor != null && floor <= lowerTarget - 40;
    cleanSinceMs = clean ? (cleanSinceMs ?? now) : null;
    if (level > 0 && cleanSinceMs != null && now - cleanSinceMs >= 30000 && now - lastChangeMs >= 30000) {
      drainAllowanceMs = accepted; drainUntilMs = now + 2000;
      level--; lastChangeMs = now; pressureWindows = 0; cleanSinceMs = null;
      return result(true, 'stable-network');
    }
    return result();
  }

  function sampleStats(current, previous) {
    if (!previous || current.id !== previous.id || current.codecId !== previous.codecId) return null;
    const intervalMs = Math.round(current.timestamp - previous.timestamp);
    if (!Number.isFinite(intervalMs) || intervalMs < 500 || intervalMs > 6000) return null;
    const delta = key => {
      const a = valid(current[key]), b = valid(previous[key]);
      return a == null || b == null ? null : a - b;
    };
    const frames = delta('framesDecoded'), emitted = delta('jitterBufferEmittedCount');
    const dropped = delta('framesDropped'), freezes = delta('freezeCount');
    if (frames == null || frames < 0 || frames > 2048 ||
        [emitted, dropped, freezes, delta('totalDecodeTime'), delta('jitterBufferDelay'),
          delta('jitterBufferTargetDelay'), delta('jitterBufferMinimumDelay')].some(v => v != null && v < 0) ||
        [dropped, freezes].some(v => v != null && v > 2048)) return null;
    const average = (key, count) => {
      const total = delta(key);
      if (total == null || count == null || count <= 0) return null;
      const value = total * 1000 / count;
      return value >= 0 && value <= 5000 ? value : null;
    };
    return {
      intervalMs, frames, dropped, freezes,
      decodeMs: average('totalDecodeTime', frames),
      actualDelayMs: average('jitterBufferDelay', emitted),
      targetDelayMs: average('jitterBufferTargetDelay', emitted),
      // RTP interarrival jitter is not equivalent to the jitter-buffer floor.
      minimumDelayMs: average('jitterBufferMinimumDelay', emitted)
    };
  }

  // requestVideoFrameCallback timestamps are a compositor observation, not an
  // input-to-photon measurement. Never synthesize cadence from timeupdate events.
  function present(nowMs, presentedFrames) {
    if (valid(nowMs) == null || !Number.isInteger(presentedFrames) || presentedFrames < 0) return null;
    const old = presentation;
    if (!old || nowMs < old.lastMs || nowMs - old.lastMs > 6000 || presentedFrames < old.lastCount) {
      presentation = { startMs: nowMs, lastMs: nowMs, startCount: presentedFrames, lastCount: presentedFrames, gapMs: 0, complete: true };
      return null;
    }
    if (presentedFrames === old.lastCount) return null;
    // A busy JS thread can miss callbacks while the compositor keeps playing.
    // Do not mislabel that callback gap as a real video freeze on the wire.
    if (presentedFrames - old.lastCount !== 1) old.complete = false;
    old.gapMs = Math.max(old.gapMs, nowMs - old.lastMs);
    old.lastMs = nowMs; old.lastCount = presentedFrames;
    const intervalMs = Math.round(nowMs - old.startMs), frames = presentedFrames - old.startCount;
    if (intervalMs < 500) return null;
    const result = old.complete && intervalMs <= 6000 && frames > 0 && frames <= 2048
      ? { intervalMs, frames, maxGapMs: Math.min(6000, Math.round(old.gapMs)) } : null;
    presentation = { startMs: nowMs, lastMs: nowMs, startCount: presentedFrames, lastCount: presentedFrames, gapMs: 0, complete: true };
    return result;
  }

  return {
    targetMs, observe, pressureDelayMs, sampleStats, present,
    resetPresentation() { presentation = null; },
    reset() {
      level = 0; pressureWindows = 0; cleanSinceMs = null;
      lastChangeMs = -Infinity; lastSampleMs = null; presentation = null;
      drainAllowanceMs = null; drainUntilMs = -Infinity;
    }
  };
}
