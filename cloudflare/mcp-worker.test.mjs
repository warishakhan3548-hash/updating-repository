import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { AiDevice, canonical, normalizeDeviceActions, toolsForDevice, validateArguments, TOOLS, toolResult } from './mcp-worker.js';

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
const listTools = async f => (await (await f.obj.fetch(f.request(`/mcp/${id}/${clientToken}`, { jsonrpc: '2.0', id: 2, method: 'tools/list' }))).json()).result.tools;
const actionEnum = tools => tools.find(tool => tool.name === 'phone_action').inputSchema.properties.action.enum;

test('strict arguments reject nonfinite, missing and out of range coordinates, unknown fields and oversized text', () => {
  assert.ok(validateArguments('phone_action', args));
  for (const bad of [{ ...args, x: NaN }, { ...args, x: 1.001 }, { ...args, y: undefined }, { ...args, x: '0.4' }, { ...args, shell: 'anything' }, { ...args, screenVersion: -1 }, { ...args, action: 'swipe' }, { ...args, action: 'type', text: 'a'.repeat(1001) }]) assert.equal(validateArguments('phone_action', bad), false);
  assert.ok(validateArguments('phone_action', { ...args, action: 'type', text: 'Hello' }));
  assert.ok(validateArguments('phone_action', { ...args, action: 'open_app', app: 'ChatGPT' }));
  assert.equal(validateArguments('phone_action', { ...args, action: 'open_app' }), false);
  assert.equal(validateArguments('phone_action', { ...args, action: 'open_app', app: '   ' }), false);
  assert.equal(validateArguments('phone_observe', { quality: 'invalid' }), false);
});

test('drag accepts bounded normalized paths and rejects malformed paths', () => {
  const drag = { ...args, action: 'drag', x: undefined, y: undefined,
    points: [{ x: 0.10, y: 0.80 }, { x: 0.14, y: 0.72 }, { x: 0.22, y: 0.64 }], durationMs: 420 };
  assert.equal(validateArguments('phone_action', drag), true);
  assert.equal(validateArguments('phone_action', { ...drag, points: [{ x: 0.1, y: 0.8 }] }), false);
  assert.equal(validateArguments('phone_action', { ...drag, points: [{ x: 0.1, y: 0.8 }, { x: 1.1, y: 0.4 }] }), false);
  assert.equal(validateArguments('phone_action', { ...drag, points: [{ x: 0.1, y: 0.8 }, { x: 0.2, y: 0.4, z: 0.3 }] }), false);
  assert.equal(validateArguments('phone_action', { ...drag, points: Array.from({ length: 25 }, (_, i) => ({ x: i / 24, y: 0.5 })) }), false);
});

test('deep canonicalization makes nested drag retries independent of object key order', () => {
  const a = { action: 'drag', points: [{ x: 0.2, y: 0.8 }, { x: 0.7, y: 0.3 }], outer: { b: 2, a: 1 } };
  const b = { outer: { a: 1, b: 2 }, points: [{ y: 0.8, x: 0.2 }, { y: 0.3, x: 0.7 }], action: 'drag' };
  assert.equal(canonical(a), canonical(b));
});

test('MCP initialization negotiates a supported version and images are first-class content', async () => {
  const f = await fixture();
  const response = await f.obj.fetch(f.request(`/mcp/${id}/${clientToken}`, { jsonrpc: '2.0', id: 0, method: 'initialize', params: { protocolVersion: '2025-06-18' } }));
  const rpc = await response.json(); assert.equal(rpc.result.protocolVersion, '2025-06-18'); assert.ok(rpc.result.capabilities.tools);
  assert.equal(toolResult({ image: { mimeType: 'image/jpeg', data: 'aaa' }, screenVersion: 1 }).content[1].type, 'image');
  assert.equal(TOOLS.length, 3);
});

test('capability negotiation defaults old APKs to legacy actions and ignores unknown future actions', () => {
  const legacy = normalizeDeviceActions(undefined);
  assert.equal(legacy.includes('two_finger'), false);
  assert.equal(actionEnum(toolsForDevice(undefined)).includes('two_finger'), false);

  const current = normalizeDeviceActions([...legacy, 'two_finger', 'future_action']);
  assert.equal(current.includes('two_finger'), true);
  assert.equal(current.includes('future_action'), false);
  assert.equal(actionEnum(toolsForDevice(current)).includes('two_finger'), true);
  assert.equal(normalizeDeviceActions('not-an-array'), null);
});

test('connected APK capabilities gate tools and stale cached actions before device dispatch', async () => {
  const f = await fixture(); f.connect();
  await f.obj.webSocketMessage(f.ws, JSON.stringify({ type: 'ready', runId: 'legacy-run' }));
  assert.equal(actionEnum(await listTools(f)).includes('two_finger'), false);

  const twoFinger = {
    ...args,
    actionId: 'step-two-finger-1',
    action: 'two_finger',
    x: 0.2, y: 0.7, toX: 0.3, toY: 0.5,
    secondX: 0.8, secondY: 0.7, secondToX: 0.7, secondToY: 0.5,
    durationMs: 240
  };
  const refused = await result(await f.call('phone_action', twoFinger));
  assert.equal(refused.error, 'UNSUPPORTED_DEVICE_ACTION');
  assert.equal(f.sent.filter(message => message.type === 'request').length, 0);
  assert.equal(f.ctx.storage.values.has(`action:${twoFinger.actionId}`), false);

  const upgraded = [...normalizeDeviceActions(undefined), 'two_finger'];
  await f.obj.webSocketMessage(f.ws, JSON.stringify({ type: 'ready', runId: 'new-run', actions: upgraded }));
  assert.equal(actionEnum(await listTools(f)).includes('two_finger'), true);
  assert.equal(f.obj.config.controlActions.includes('two_finger'), true);

  const restarted = await fixture(f.ctx.storage);
  assert.equal(actionEnum(await listTools(restarted)).includes('two_finger'), true);
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

test('status distinguishes unfinished setup from an active phone without requiring mobile data', async () => {
  const f = await fixture();
  const setup = await result(await f.call('phone_status'));
  assert.equal(setup.online, false); assert.equal(setup.connectionState, 'setup_required');
  assert.match(setup.next, /full-screen sharing/);
  assert.equal(setup.supportedActions.includes('two_finger'), false);
  f.connect(); await f.obj.webSocketMessage(f.ws, JSON.stringify({ type: 'ready', runId: 'run-first' }));
  assert.equal((await result(await f.call('phone_status'))).connectionState, 'sharing');
  f.ws.a.lastSeen = Date.now() - 60_000;
  const lost = await result(await f.call('phone_status'));
  assert.equal(lost.online, false); assert.equal(lost.connectionState, 'disconnected');
  assert.match(lost.next, /Wi-Fi internet is sufficient/);
});

test('re-registering the same saved link keeps its authentication and live socket', async () => {
  const f = await fixture(); f.connect();
  await f.obj.webSocketMessage(f.ws, JSON.stringify({ type: 'ready', runId: 'run-first' }));
  const response = await f.obj.fetch(f.request(`/v1/connectors/${id}/register`, { clientToken }, deviceToken));
  assert.equal(response.status, 200); assert.equal(f.ws.readyState, 1);
  assert.equal((await result(await f.call('phone_status'))).online, true);
  assert.equal(f.obj.config.lastRunId, 'run-first');
});

test('STOP cancels pending input, but status remains authenticated and the same link can resume', async () => {
  const f = await fixture(); f.connect();
  await f.obj.webSocketMessage(f.ws, JSON.stringify({ type: 'ready', runId: 'run-first' }));
  const pending = f.call('phone_action', args);
  while (!f.obj.pending) await new Promise(resolve => setImmediate(resolve));
  await f.obj.webSocketMessage(f.ws, JSON.stringify({ type: 'stopped', runId: 'run-first' }));
  assert.equal((await result(await pending)).error, 'STOPPED');
  assert.equal(f.ws.readyState, 3);
  const stopped = await result(await f.call('phone_status'));
  assert.equal(stopped.connectionState, 'stopped'); assert.equal(stopped.sharing, false);
  const asleep = await fixture(f.ctx.storage);
  assert.equal((await result(await asleep.call('phone_status'))).connectionState, 'stopped');
  asleep.connect(); await asleep.obj.webSocketMessage(asleep.ws, JSON.stringify({ type: 'ready', runId: 'run-second' }));
  assert.equal((await result(await asleep.call('phone_status'))).online, true);
  assert.equal((await result(await asleep.call('phone_action', args))).replayed, true);
});

test('delayed pause from an old service cannot stop the new service, and pause requires device auth', async () => {
  const f = await fixture(); f.connect();
  await f.obj.webSocketMessage(f.ws, JSON.stringify({ type: 'ready', runId: 'run-second' }));
  const path = `/v1/connectors/${id}/pause`;
  assert.equal((await f.obj.fetch(f.request(path, { runId: 'run-second' }, clientToken))).status, 401);
  assert.equal((await f.obj.fetch(f.request(path, { runId: 'run-first' }, deviceToken))).status, 200);
  assert.equal((await result(await f.call('phone_status'))).online, true);
  assert.equal((await f.obj.fetch(f.request(path, { runId: 'run-second' }, deviceToken))).status, 200);
  assert.equal((await result(await f.call('phone_status'))).connectionState, 'stopped');
});

test('animated observations retain their usable ticket and target rejection retains fresh image and reason', async () => {
  const animated = toolResult({ settled: false, observationId: args.observationId, screenVersion: 4,
    image: { mimeType: 'image/jpeg', data: 'jpeg-base64', width: 1, height: 1 } });
  assert.equal(animated.isError, false); assert.equal(JSON.parse(animated.content[0].text).observationId, args.observationId);
  const f = await fixture(); f.connect();
  const pending = f.call('phone_action', args);
  await f.complete({ error: 'STALE_SCREEN', reason: 'TARGET_CHANGED', applied: false,
    observationId: 'new-observation-0001', screenVersion: 5, image: { mimeType: 'image/jpeg', data: 'fresh-base64' } });
  const reply = (await (await pending).json()).result;
  assert.equal(reply.isError, true); assert.equal(reply.content[1].data, 'fresh-base64');
  assert.equal(JSON.parse(reply.content[0].text).reason, 'TARGET_CHANGED');
  const retry = await result(await f.call('phone_action', args));
  assert.equal(retry.replayed, true); assert.equal(retry.applied, false); assert.equal(f.sent.length, 1);
});
