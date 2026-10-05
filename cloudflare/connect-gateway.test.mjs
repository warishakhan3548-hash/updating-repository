import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(new URL('./connect-gateway/_worker.js', import.meta.url), 'utf8');
const { default: gateway } = await import(`data:text/javascript,${encodeURIComponent(source)}`);

test('redeem keeps the same request, token and body, without an HTTP redirect', async () => {
  const request = new Request('https://aaris-remote-connect.pages.dev/v1/sessions/redeem', {
    method: 'POST', headers: { authorization: 'Bearer synthetic-token' },
    body: JSON.stringify({ code: '123456789012', controllerToken: 'stable-synthetic-token' })
  });
  const response = Response.json({ ok: true, sessionId: 'synthetic-session' });
  const result = await gateway.fetch(request, { CORE: { async fetch(forwarded) {
    assert.equal(forwarded, request);
    assert.equal(forwarded.headers.get('authorization'), 'Bearer synthetic-token');
    assert.equal((await forwarded.json()).controllerToken, 'stable-synthetic-token');
    return response;
  } } });
  assert.equal(result, response);
});

test('WebSocket upgrade is returned intact with its replay cursor', async () => {
  const request = new Request('https://aaris-remote-connect.pages.dev/v1/sessions/synthetic/socket?after=17', {
    headers: { upgrade: 'websocket', authorization: 'Bearer synthetic-token' }
  });
  const upgrade = { status: 101, webSocket: {} };
  const result = await gateway.fetch(request, { CORE: { async fetch(forwarded) {
    assert.equal(forwarded, request);
    assert.equal(new URL(forwarded.url).searchParams.get('after'), '17');
    return upgrade;
  } } });
  assert.equal(result, upgrade);
});

test('authorization errors pass through instead of becoming a new session', async () => {
  const response = Response.json({ error: 'unauthorized' }, { status: 401 });
  assert.equal(await gateway.fetch(new Request('https://example.pages.dev/v1/sessions/synthetic'), {
    CORE: { fetch: async () => response }
  }), response);
});

test('unrelated paths and missing bindings fail closed', async () => {
  let called = false;
  assert.equal((await gateway.fetch(new Request('https://example.pages.dev/other'), {
    CORE: { fetch: async () => { called = true; } }
  })).status, 404);
  assert.equal(called, false);
  const missing = await gateway.fetch(new Request('https://example.pages.dev/healthz'), {});
  assert.equal(missing.status, 503);
  assert.equal(missing.headers.get('cache-control'), 'no-store');
});
