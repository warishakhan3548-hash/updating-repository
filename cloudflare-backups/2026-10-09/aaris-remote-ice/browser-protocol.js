// Wire adapter for Android ControlProtocol v1. Long values stay BigInt: lease
// secrets and sequence numbers cannot safely pass through a JavaScript Number.
export function createBrowserProtocol() {
  const kinds = { tap: 3, longPress: 4, swipe: 5, back: 6, home: 7, recents: 9, text: 10, drag: 12 };
  function unit(value) {
    if (!Number.isFinite(value) || value < 0 || value > 1) throw new Error('Invalid screen coordinate');
    return Math.trunc(Math.fround(Math.fround(value) * 65535));
  }
  function decode(buffer) {
    const v = new DataView(buffer);
    if (v.byteLength < 2 || v.getUint8(0) !== 1) return null;
    if (v.getUint8(1) === 1 && v.byteLength === 22) return {
      type: 'hello', secret: v.getBigInt64(2), generation: v.getInt32(10),
      width: v.getInt32(14), height: v.getInt32(18)
    };
    if (v.getUint8(1) === 13 && v.byteLength === 11) return {
      type: 'result', sequence: v.getBigInt64(2), applied: v.getUint8(10) === 1
    };
    return null;
  }
  function shortPacket(type, hello) {
    const b = new ArrayBuffer(10), v = new DataView(b);
    v.setUint8(0, 1); v.setUint8(1, type); v.setBigInt64(2, hello.secret); return b;
  }
  function command(action, hello, sequence, args = {}) {
    if (!kinds[action] || !hello || typeof sequence !== 'bigint' || sequence <= 0n) throw new Error('Control is not ready');
    const encoded = action === 'text' ? new Text --- TRUNCATED --- 4,701 chars