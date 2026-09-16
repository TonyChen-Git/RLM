'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  TaskScopeError,
  assertTaskIdentity,
  assertTaskScope,
  normalizeWorkspacePath
} = require('../task-scope');

function task(overrides = {}) {
  return {
    workspacePath: '/workspace/project',
    mode: 'agent',
    status: 'idle',
    backendID: 'ollama/profile-id',
    modelID: 'qwen3.8',
    ...overrides
  };
}

const expected = {
  workspacePath: '/workspace/project',
  mode: 'agent',
  backendID: 'ollama/profile-id',
  modelID: 'qwen3.8'
};

test('accepts only an exact canonical workspace, mode, backend, and model', () => {
  assert.equal(assertTaskScope(task(), expected).modelID, 'qwen3.8');
  assert.throws(
    () => assertTaskScope(task({ workspacePath: '/workspace/other' }), expected),
    TaskScopeError
  );
  assert.throws(() => assertTaskScope(task({ mode: 'plan' }), expected), TaskScopeError);
  assert.throws(() => assertTaskScope(task({ backendID: 'mlx' }), expected), TaskScopeError);
  assert.throws(() => assertTaskScope(task({ modelID: 'other' }), expected), TaskScopeError);
});

test('requires a fetched task to repeat the exact requested opaque ID', () => {
  assert.equal(assertTaskIdentity({ id: 'task-1' }, 'task-1').id, 'task-1');
  assert.throws(() => assertTaskIdentity({ id: 'task-2' }, 'task-1'), TaskScopeError);
  assert.throws(() => assertTaskIdentity({ id: '../task' }, '../task'), TaskScopeError);
});

test('rejects traversal aliases, double-slash roots, and control data', () => {
  assert.equal(normalizeWorkspacePath('/workspace/project/'), '/workspace/project');
  assert.throws(() => normalizeWorkspacePath('/workspace/../other'), TaskScopeError);
  assert.throws(() => normalizeWorkspacePath('//server/share'), TaskScopeError);
  assert.throws(() => normalizeWorkspacePath('/workspace\nother'), TaskScopeError);
});

test('explicit open/diff scope may accept any supported mode and route', () => {
  const result = assertTaskScope(task({ mode: 'plan', backendID: 'mlx' }), expected, {
    verifyMode: false,
    verifyRoute: false
  });
  assert.equal(result.mode, 'plan');
});
