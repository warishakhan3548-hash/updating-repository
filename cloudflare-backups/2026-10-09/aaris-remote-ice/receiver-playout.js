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
    // allowance, never anything above it, the --- TRUNCATED --- 7,429 chars