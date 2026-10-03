import test from 'node:test';
import assert from 'node:assert/strict';
import { TOOLS, validateArguments } from './mcp-worker.js';

const base = {
  actionId: 'step-gesture-0001',
  observationId: 'observation-gesture-0001',
  screenVersion: 7
};

test('phone_action advertises curved and two-finger gesture powers', () => {
  const phoneAction = TOOLS.find(tool => tool.name === 'phone_action');
  assert.ok(phoneAction);
  const actions = phoneAction.inputSchema.properties.action.enum;
  assert.ok(actions.includes('gesture_path'));
  assert.ok(actions.includes('two_finger'));
  assert.equal(phoneAction.inputSchema.properties.points.maxItems, 32);
});

test('gesture_path requires a bounded list of strict normalized waypoints', () => {
  const valid = {
    ...base,
    action: 'gesture_path',
    durationMs: 320,
    points: [
      { x: 0.15, y: 0.75 },
      { x: 0.45, y: 0.35 },
      { x: 0.80, y: 0.55 }
    ]
  };
  assert.equal(validateArguments('phone_action', valid), true);
  assert.equal(validateArguments('phone_action', { ...valid, points: [{ x: 0.1, y: 0.2 }] }), false);
  assert.equal(validateArguments('phone_action', { ...valid, points: [{ x: 0.1, y: 0.2 }, { x: 1.1, y: 0.3 }] }), false);
  assert.equal(validateArguments('phone_action', { ...valid, points: [{ x: 0.1, y: 0.2, pressure: 1 }, { x: 0.2, y: 0.3 }] }), false);
});

test('two_finger requires both complete normalized pointer paths', () => {
  const valid = {
    ...base,
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
  assert.equal(validateArguments('phone_action', valid), true);
  const missing = { ...valid };
  delete missing.secondToY;
  assert.equal(validateArguments('phone_action', missing), false);
  assert.equal(validateArguments('phone_action', { ...valid, secondToX: Number.NaN }), false);
  assert.equal(validateArguments('phone_action', { ...valid, durationMs: 79 }), false);
});
