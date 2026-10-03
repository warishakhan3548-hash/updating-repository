import test from 'node:test';
import assert from 'node:assert/strict';
import { TOOLS, canonical, validateArguments } from './mcp-worker.js';

const base = {
  actionId: 'step-twofinger-0001',
  observationId: 'observation-twofinger-0001',
  screenVersion: 9,
  action: 'two_finger',
  durationMs: 450,
  firstX: 0.40,
  firstY: 0.50,
  firstToX: 0.25,
  firstToY: 0.50,
  secondX: 0.60,
  secondY: 0.50,
  secondToX: 0.75,
  secondToY: 0.50
};

test('phone_action advertises and validates the bounded two-finger primitive', () => {
  const phoneAction = TOOLS.find(tool => tool.name === 'phone_action');
  assert.ok(phoneAction.inputSchema.properties.action.enum.includes('two_finger'));
  assert.equal(validateArguments('phone_action', base), true);

  const missing = { ...base };
  delete missing.secondToY;
  assert.equal(validateArguments('phone_action', missing), false);
  assert.equal(validateArguments('phone_action', { ...base, firstX: -0.01 }), false);
  assert.equal(validateArguments('phone_action', { ...base, secondToX: 1.01 }), false);
  assert.equal(validateArguments('phone_action', { ...base, durationMs: 79 }), false);
});

test('two-finger retries remain deep-canonicalized regardless of argument key order', () => {
  const reordered = Object.fromEntries(Object.entries(base).reverse());
  assert.equal(canonical(base), canonical(reordered));
});
