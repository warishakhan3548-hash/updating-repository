import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { AiDevice, validateArguments, TOOLS, toolResult } from './mcp-worker.js';

const id = '1'.repeat(64), deviceToken = '2'.repeat(64), clientToken = '3'.repeat(64);
const base = 'https://aaris-phone-mcp.example';
const args = { actionId: 'step-00000001', observationId: 'observation-000000001', screenVersion: 4, action: 'tap', x: 0.25, y: 0.75 };
class Storage {
  values = new Map();
  async get(k) { return structuredClone(this.values.get(k)); }
  async put(k, v) { this.values.set(k, structuredClone(v)); }
  async list({ prefix }) { return new Map([...this.values].filter(([k]) => k.startsWith(prefix)).map(([k,v]) => [k, structuredClone(v)])); }
  async delete(keys) { for (const k of Array.isArray(keys) ? keys : [keys]) this.values.delete(k); }
  async setAlarm(time) { this.alarm = time; }
}
async function fixture(storage = new Storage()) {
  const sockets = [];
  const ctx = { storage, blockConcurrencyWhile: fn => { ctx.ready = fn(); }, getWebSockets: () => sockets };
  const obj = new AiDevice(ctx, {}); await ctx.ready;
  const request = (path, body, token, extra = {}) => new Request(base + path, { method: 'POST', headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}), ...extra }, body: JSON.stringify(body) });
  if (!obj.config) assert.equal((await obj.fetch(request(`/v1/connectors/${id}/register`, { clientToken }, deviceToken))).status, 200);
  const call = (name, arguments_ = {}) => obj.fetch(request(`/mcp/${id}/${clientToken}`, { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: arguments_ } }));
  const sent = [];
  const ws = { readyState: 1, a: { ready: true, lastSeen: Date.now(), runId: 'service-run-1' }, deserializeAttachment() { return this.a; }, serializeAttachment(a) { this.a = a; }, send(raw) { sent.push(JSON.parse(raw)); }, close() { this.readyState = 3; } };
  const connect = () => sockets.push(ws);
  const complete = async result => {
    for (let i = 0; i < 100 && !obj.pending; i++) await new Promise(resolve => setImmediate(resolve));
    assert.ok(obj.pending, 'Expected an admitted device request');
    await obj.webSocketMessage(ws, JSON.stringify({ type: 'result', requestId: obj.pending.requestId, result }));
  };
  return { obj, ctx, request, call, sent, ws, connect, complete };
}
const result = async response => JSON.parse((await response.json()).result.content[0].text);

test('strict arguments reject nonfinite, missing and out of range coordinates, unknown fields and oversized text', () => {
  assert.ok(validateArguments('phone_action', args));
  for (const bad of [{ ...args, x: NaN }, { ...args, x: 1.001 }, { ...args, y: undefined }, { ...args, x: '0.4' }, { ...args, shell: 'anything' }, { ...args, screenVersion: -1 }, { ...args, action: 'swipe' }, { ...args, action: 'type', text: 'a'.repeat(1001) }]) assert.equal(validateArguments('phone_action', bad), false);
  assert.ok(validateArguments('phone_action', { ...args, action: 'type', text: 'Hello' }));
  assert.equal(validateArguments('phone_observe', { quality: 'invalid' }), false);
});
test('MCP initialization negotiates a supported version and images are first-class content', async () => {
  const f = await fixture();
  const response = await f.obj.fetch(f.request(`/mcp/${id}/${clientToken}`, { jsonrpc: '2.0', id: 0, method: 'initialize', params: { protocolVersion: '2025-06-18' } }));
  const rpc = await response.json(); assert.equal(rpc.result.protocolVersion, '2025-06-18'); assert.ok(rpc.result.capabilities.tools);
  assert.equal(toolResult({ image: { mimeType: 'image/jpeg', data: 'aaa' }, screenVersion: 1 }).content[1].type, 'image');
  assert.equal(TOOLS.length, 3);
});
test('unauthorized links and credential replacement cannot reach a phone', async () => {
  const f = await fixture(); f.connect();
  const response = await f.obj.fetch(f.request(`/mcp/${id}/${'0'.repeat(64)}`, {})); assert.equal(response.status, 401);
  const takeover = await f.obj.fetch(f.request(`/v1/connectors/${id}/register`, { clientToken }, '4'.repeat(64)));
  assert.equal(takeover.status, 401); assert.equal(f.sent.length, 0);
});
test('invalid Origin is rejected before accessing any Durable Object', async () => {
  let accessed = false;
  const response = await worker.fetch(new Request(`${base}/mcp/${id}/${clientToken}`, { headers: { Origin: 'https://untrusted.example' } }), { AI_DEVICES: { idFromName() { accessed = true; } } });
  assert.equal(response.status, 403); assert.equal(accessed, false);
});
test('offline phone rejects actions without queuing them for a future connection', async () => {
  const f = await fixture(); assert.equal((await result(await f.call('phone_action', args))).error, 'PHONE_OFFLINE');
  assert.equal(f.sent.length, 0); assert.equal(f.ctx.storage.values.has(`action:${args.actionId}`), false);
});
test('one action returns its image; retry across hibernation returns outcome without re-execution', async () => {
  const f = await fixture(); f.connect();
  const pending = f.call('phone_action', args);
  await f.complete({ applied: true, screenVersion: 5, image: { mimeType: 'image/jpeg', data: 'jpeg-base64' } });
  const first = await (await pending).json(); assert.equal(first.result.content[1].type, 'image'); assert.equal(f.sent.length, 1);
  const restarted = await fixture(f.ctx.storage); restarted.connect();
  const replay = await result(await restarted.call('phone_action', args));
  assert.equal(replay.applied, true); assert.equal(replay.replayed, true); assert.equal(restarted.sent.length, 0);
  const serialized = JSON.stringify([...f.ctx.storage.values]);
  assert.equal(serialized.includes('jpeg-base64'), false); assert.equal(serialized.includes('0.25'), false);
});
test('ambiguous disconnect is durable and must never replay the same action', async () => {
  const f = await fixture(); f.connect();
  const pending = f.call('phone_action', args);
  while (!f.obj.pending) await new Promise(resolve => setImmediate(resolve));
  await f.obj.webSocketClose(f.ws);
  assert.equal((await result(await pending)).applied, null);
  const retry = await result(await f.call('phone_action', args)); assert.equal(retry.replayed, true); assert.equal(f.sent.length, 1);
});
test('durably admitted but unfinished action remains unknown after a process reset', async () => {
  const f = await fixture(); f.connect(); const pending = f.call('phone_action', args);
  while (!f.obj.pending) await new Promise(resolve => setImmediate(resolve));
  const restarted = await fixture(f.ctx.storage); restarted.connect();
  assert.equal((await result(await restarted.call('phone_action', args))).error, 'OUTCOME_UNKNOWN'); assert.equal(restarted.sent.length, 0);
  f.obj.cancelPending('OUTCOME_UNKNOWN'); await pending;
});
test('concurrent actions fail busy and cannot reorder input', async () => {
  const f = await fixture(); f.connect(); const first = f.call('phone_action', args);
  while (!f.obj.pending) await new Promise(resolve => setImmediate(resolve));
  const second = await result(await f.call('phone_action', { ...args, actionId: 'step-00000002' })); assert.equal(second.error, 'BUSY');
  await f.complete({ applied: true }); await first; assert.equal(f.sent.length, 1);
});
test('actionId reuse with changed coordinates is refused', async () => {
  const f = await fixture(); f.connect(); const first = f.call('phone_action', args);
  await f.complete({ applied: true }); await first;
  const changed = await result(await f.call('phone_action', { ...args, x: 0.9 })); assert.equal(changed.error, 'ACTION_ID_CONFLICT'); assert.equal(f.sent.length, 1);
});
test('revoke closes the phone and invalidates the MCP link', async () => {
  const f = await fixture(); f.connect();
  assert.equal((await f.obj.fetch(f.request(`/v1/connectors/${id}/revoke`, { clientToken }, deviceToken))).status, 200);
  assert.equal(f.ws.readyState, 3); assert.equal((await f.call('phone_observe')).status, 401);
});
test('delayed revoke for a previous link cannot stop a newly rotated link', async () => {
  const f = await fixture();
  const nextToken = '5'.repeat(64);
  assert.equal((await f.obj.fetch(f.request(`/v1/connectors/${id}/register`, { clientToken: nextToken }, deviceToken))).status, 200);
  assert.equal((await f.obj.fetch(f.request(`/v1/connectors/${id}/revoke`, { clientToken }, deviceToken))).status, 409);
  assert.equal(f.obj.config.revoked, false);
});
test('a different connector cannot receive another phone request', async () => {
  const a = await fixture(), b = await fixture(); a.connect(); b.connect();
  const pending = a.call('phone_observe');
  await a.complete({ screenVersion: 2, image: { mimeType: 'image/jpeg', data: 'phone-a' } });
  assert.equal((await (await pending).json()).result.content[1].data, 'phone-a'); assert.equal(b.sent.length, 0);
});
test('notifications, GET, unsupported versions and malformed requests have protocol-correct responses', async () => {
  const f = await fixture();
  assert.equal((await f.obj.fetch(f.request(`/mcp/${id}/${clientToken}`, { jsonrpc: '2.0', method: 'notifications/initialized' }))).status, 202);
  assert.equal((await f.obj.fetch(new Request(`${base}/mcp/${id}/${clientToken}`))).status, 405);
  assert.equal((await f.obj.fetch(f.request(`/mcp/${id}/${clientToken}`, {}, null, { 'MCP-Protocol-Version': '1900-01-01' }))).status, 400);
  assert.equal((await f.obj.fetch(f.request(`/mcp/${id}/${clientToken}`, []))).status, 400);
});
