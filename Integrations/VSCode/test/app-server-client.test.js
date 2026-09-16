'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  LumaChatAppServerClient,
  LumaChatAppServerError,
  validateServerURL
} = require('../app-server-client');

const SERVER_TOKEN = 's'.repeat(32);

function jsonResponse(value, status = 200, headers = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json', ...headers }
  });
}

test('server URL policy defaults to loopback and requires TLS plus token remotely', () => {
  assert.equal(validateServerURL('http://127.0.0.1:32189', false, '').origin,
    'http://127.0.0.1:32189');
  assert.equal(validateServerURL('http://[::1]:32189', false, '').origin,
    'http://[::1]:32189');
  assert.throws(
    () => validateServerURL('https://runner.example.test', false, SERVER_TOKEN),
    (error) => error.code === 'REMOTE_ENDPOINT_REFUSED'
  );
  assert.throws(
    () => validateServerURL('http://runner.example.test', true, SERVER_TOKEN),
    (error) => error.code === 'REMOTE_ENDPOINT_REFUSED'
  );
  assert.throws(
    () => validateServerURL('https://runner.example.test', true, ''),
    (error) => error.code === 'MISSING_TOKEN'
  );
  assert.equal(
    validateServerURL('https://runner.example.test', true, SERVER_TOKEN).origin,
    'https://runner.example.test'
  );
});

test('task creation sends one exact backend/model request with Bearer auth', async () => {
  const calls = [];
  const client = new LumaChatAppServerClient({
    token: SERVER_TOKEN,
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      return jsonResponse({ id: 'task-1', status: 'idle' }, 201);
    }
  });

  const task = await client.createTask({
    mode: 'agent',
    title: 'Editor task',
    workspacePath: '/workspace',
    backendID: 'ollama',
    modelID: 'qwen3.8'
  });

  assert.equal(task.id, 'task-1');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'http://127.0.0.1:32189/v1/tasks');
  assert.equal(calls[0].options.redirect, 'error');
  assert.equal(calls[0].options.headers.Authorization, `Bearer ${SERVER_TOKEN}`);
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    mode: 'agent',
    workspacePath: '/workspace',
    backendID: 'ollama',
    modelID: 'qwen3.8',
    title: 'Editor task'
  });
});

test('task modes and approval decisions use the exact v1 wire values', async () => {
  const calls = [];
  const client = new LumaChatAppServerClient({
    token: SERVER_TOKEN,
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      return jsonResponse({
        requestID: '00000000-0000-0000-0000-000000000001',
        taskID: 'task-1',
        status: 'running',
        accepted: true
      }, 202);
    }
  });

  assert.throws(() => client.createTask({
    mode: 'review',
    workspacePath: '/workspace',
    backendID: 'ollama',
    modelID: 'qwen3.8'
  }), (error) => error.code === 'INVALID_ARGUMENT');
  await client.approve('task-1', 'approval-1', 'allowForTask');
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    approvalID: 'approval-1',
    decision: 'allowForTask'
  });
});

test('task acknowledgements and diffs must match the exact requested task', async () => {
  const responses = [
    jsonResponse({
      requestID: 'request-1',
      taskID: 'other-task',
      status: 'running',
      accepted: true
    }, 202),
    jsonResponse({
      taskID: 'task-1',
      diff: 'diff --git a/a b/a\n',
      changedPaths: ['a'],
      truncated: true,
      generatedAt: '2026-01-01T00:00:00Z'
    })
  ];
  const client = new LumaChatAppServerClient({
    token: SERVER_TOKEN,
    fetchImpl: async () => responses.shift()
  });
  await assert.rejects(client.pause('task-1'), (error) => error.code === 'PROTOCOL_VIOLATION');
  await assert.rejects(client.diff('task-1'), (error) => error.code === 'TRUNCATED_DIFF');
});

test('unavailable configured server fails after one attempt without fallback', async () => {
  let attempts = 0;
  const client = new LumaChatAppServerClient({
    token: SERVER_TOKEN,
    fetchImpl: async () => {
      attempts += 1;
      throw new Error('connection refused');
    }
  });

  await assert.rejects(
    client.health(),
    (error) => error instanceof LumaChatAppServerError && error.code === 'UNAVAILABLE'
  );
  assert.equal(attempts, 1);
});

test('model/backend errors preserve only a bounded machine code', async () => {
  const client = new LumaChatAppServerClient({
    token: 'must-never-appear'.repeat(3),
    fetchImpl: async () => jsonResponse({
      error: {
        code: 'MODEL_UNAVAILABLE',
        message: 'must-never-appear'
      }
    }, 503)
  });

  await assert.rejects(client.createTask({
    mode: 'agent',
    workspacePath: '/workspace',
    backendID: 'selected-backend',
    modelID: 'selected-model'
  }), (error) => {
    assert.equal(error.code, 'MODEL_UNAVAILABLE');
    assert.equal(error.status, 503);
    assert.doesNotMatch(error.message, /must-never-appear/u);
    return true;
  });
});

test('task IDs are validated before they enter a URL', async () => {
  let called = false;
  const client = new LumaChatAppServerClient({
    token: SERVER_TOKEN,
    fetchImpl: async () => {
      called = true;
      return jsonResponse({});
    }
  });
  assert.throws(() => client.getTask('../outside'), (error) => error.code === 'INVALID_ARGUMENT');
  assert.equal(called, false);
});

test('declared oversized responses fail closed', async () => {
  const client = new LumaChatAppServerClient({
    token: SERVER_TOKEN,
    maximumResponseBytes: 1_024,
    fetchImpl: async () => jsonResponse(
      { status: 'ok' },
      200,
      { 'content-length': '2048' }
    )
  });
  await assert.rejects(client.health(), (error) => error.code === 'RESPONSE_TOO_LARGE');
});
