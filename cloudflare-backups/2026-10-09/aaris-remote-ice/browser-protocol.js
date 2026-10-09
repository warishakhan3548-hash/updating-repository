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
    const encoded = action === 'text' ? new TextEncoder().encode(args.text || '') : null;
    if (encoded && (!encoded.length || encoded.length > 2048)) throw new Error('Text must be 1–2048 UTF-8 bytes');
    const points = args.points;
    if (action === 'drag' && (!Array.isArray(points) || points.length < 2 || points.length > 96)) throw new Error('Drag needs 2–96 points');
    const extra = { tap: 4, longPress: 6, swipe: 10, back: 0, home: 0, recents: 0,
      text: 2 + (encoded?.length || 0), drag: 3 + (points?.length || 0) * 4 }[action];
    const b = new ArrayBuffer(22 + extra), v = new DataView(b); let offset = 22;
    v.setUint8(0, 1); v.setUint8(1, kinds[action]); v.setBigInt64(2, hello.secret);
    v.setInt32(10, hello.generation); v.setBigInt64(14, sequence);
    const coordinate = (x, y) => { v.setUint16(offset, unit(x)); v.setUint16(offset + 2, unit(y)); offset += 4; };
    if (['tap', 'longPress', 'swipe'].includes(action)) coordinate(args.x, args.y);
    if (action === 'swipe') coordinate(args.toX, args.toY);
    if (action === 'drag') { v.setUint8(offset++, points.length); for (const p of points) coordinate(p.x, p.y); }
    if (['longPress', 'swipe', 'drag'].includes(action)) {
      const ms = args.durationMs ?? (action === 'longPress' ? 600 : 350);
      if (!Number.isFinite(ms)) throw new Error('Invalid gesture duration');
      v.setUint16(offset, Math.round(Math.max(action === 'longPress' ? 250 : 80, Math.min(5000, ms))));
    }
    if (encoded) { v.setUint16(offset, encoded.length); new Uint8Array(b, offset + 2).set(encoded); }
    return b;
  }
  function gestureStream(hello, sequence, streamId, phase, points, durationMs) {
    const phases = { start: 0, continue: 1, end: 2 };
    const phaseValue = phases[phase];
    if (!hello || typeof sequence !== 'bigint' || sequence <= 0n ||
        typeof streamId !== 'bigint' || streamId <= 0n ||
        phaseValue === undefined || !Array.isArray(points) ||
        points.length < 1 || points.length > 16) {
      throw new Error('Invalid live gesture segment');
    }
    const b = new ArrayBuffer(34 + points.length * 4), v = new DataView(b);
    v.setUint8(0, 1); v.setUint8(1, 17); v.setBigInt64(2, hello.secret);
    v.setInt32(10, hello.generation); v.setBigInt64(14, sequence);
    v.setBigInt64(22, streamId); v.setUint8(30, phaseValue); v.setUint8(31, points.length);
    let offset = 32;
    for (const p of points) {
      v.setUint16(offset, unit(p.x)); v.setUint16(offset + 2, unit(p.y)); offset += 4;
    }
    const ms = Number(durationMs);
    if (!Number.isFinite(ms)) throw new Error('Invalid live gesture duration');
    v.setUint16(offset, Math.round(Math.max(12, Math.min(1000, ms))));
    return b;
  }
  function point(clientX, clientY, rect, width, height) {
    if (!(width > 0 && height > 0 && rect.width > 0 && rect.height > 0)) return null;
    const scale = Math.min(rect.width / width, rect.height / height);
    const w = width * scale, h = height * scale;
    const x = (clientX - rect.left - (rect.width - w) / 2) / w;
    const y = (clientY - rect.top - (rect.height - h) / 2) / h;
    return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? { x, y } : null;
  }
  return { decode, command, gestureStream, point, heartbeat: h => shortPacket(2, h), videoReady: h => shortPacket(15, h), refresh: h => shortPacket(14, h) };
}
