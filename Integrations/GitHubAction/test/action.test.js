'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  buildReviewMessage,
  extractReport,
  run,
  waitForTask
} = require('../index');

function environment(operation = 'review') {
  return {
    INPUT_BACKEND_ID: 'ollama',
    INPUT_MODEL_ID: 'qwen3.8',
    INPUT_SERVER_TOKEN: 's'.repeat(32),
    INPUT_OPERATION: operation
  };
}

function reviewContext() {
  return {
    workspace: '/workspace',
    repository: 'owner/repository',
    baseSHA: 'a'.repeat(40),
    headSHA: 'b'.repeat(40),
    pullRequestNumber: 42,
    patch: 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n',
    eventName: 'pull_request'
  };
}

function taskSnapshot(id, status, result = undefined) {
  return {
    id,
    status,
    mode: 'plan',
    workspacePath: '/workspace',
    backendID: 'ollama',
    modelID: 'qwen3.8',
    result
  };
}

test('review uses one configured App Server/backend/model and returns result.content', async () => {
  const calls = [];
  let polls = 0;
  const client = {
    async health() { calls.push(['health']); return { status: 'ok', apiVersion: 'v1' }; },
    async createTask(body) {
      calls.push(['createTask', body]);
      return taskSnapshot('task-1', 'idle');
    },
    async sendMessage(id, body) { calls.push(['sendMessage', id, body]); return {}; },
    async getTask(id) {
      calls.push(['getTask', id]);
      polls += 1;
      return polls === 1
        ? taskSnapshot(id, 'running')
        : taskSnapshot(id, 'completed', { content: 'Review result' });
    }
  };

  const result = await run(environment(), {
    client,
    loadReviewContext: reviewContext,
    sleep: async () => {}
  });

  assert.deepEqual(result, { taskID: 'task-1', status: 'completed', report: 'Review result' });
  assert.deepEqual(calls[0], ['health']);
  assert.deepEqual(calls[1], ['createTask', {
    mode: 'plan',
    title: 'GitHub review: owner/repository',
    workspacePath: '/workspace',
    backendID: 'ollama',
    modelID: 'qwen3.8'
  }]);
  assert.equal(calls[2][0], 'sendMessage');
  assert.equal(calls[2][1], 'task-1');
  assert.match(calls[2][2].content, /BEGIN UNTRUSTED GIT DIFF/u);
  assert.equal(Object.hasOwn(calls[1][1], 'fallback'), false);
});

test('an unavailable App Server fails before Git inspection and has no fallback', async () => {
  let inspected = false;
  const client = {
    async health() { throw new Error('unavailable'); }
  };
  await assert.rejects(run(environment(), {
    client,
    loadReviewContext: () => {
      inspected = true;
      return reviewContext();
    }
  }), /unavailable/u);
  assert.equal(inspected, false);
});

test('CI refuses an awaiting-approval task instead of approving it', async () => {
  const stopped = [];
  const client = {
    async getTask(id) { return { id, status: 'awaiting_approval' }; },
    async stop(id) { stopped.push(id); }
  };
  await assert.rejects(waitForTask(client, 'task-1', {
    timeoutMs: 5_000,
    pollIntervalMs: 250,
    sleep: async () => {}
  }), /will not auto-approve/u);
  assert.equal(typeof client.approve, 'undefined');
  assert.deepEqual(stopped, ['task-1']);
});

test('timeout stops the exact task before CI fails', async () => {
  const stopped = [];
  let clock = 0;
  const client = {
    async getTask(id) { return { id, status: 'running' }; },
    async stop(id) { stopped.push(id); }
  };
  await assert.rejects(waitForTask(client, 'task-timeout', {
    timeoutMs: 5_000,
    pollIntervalMs: 5_000,
    sleep: async (milliseconds) => { clock += milliseconds; },
    now: () => clock
  }), /task_timeout_ms/u);
  assert.deepEqual(stopped, ['task-timeout']);
});

test('comment publishes only after successful LumaChat completion', async () => {
  const published = [];
  const env = {
    ...environment('comment'),
    INPUT_GITHUB_TOKEN: 'github-secret',
    GITHUB_API_URL: 'https://github.example.test/api/v3'
  };
  const client = {
    async health() { return { status: 'ok' }; },
    async createTask() { return taskSnapshot('task-comment', 'idle'); },
    async sendMessage() { return {}; },
    async getTask(id) {
      return taskSnapshot(id, 'completed', { content: 'Bounded comment' });
    }
  };
  await run(env, {
    client,
    loadReviewContext: reviewContext,
    createGitHubComment: async (request) => published.push(request)
  });
  assert.equal(published.length, 1);
  assert.equal(published[0].token, 'github-secret');
  assert.equal(published[0].markdown, 'Bounded comment');
  assert.equal(published[0].apiURL, 'https://github.example.test/api/v3');
});

test('review prompt marks patch content as untrusted data', () => {
  const message = buildReviewMessage(
    { operation: 'review', prompt: '' },
    reviewContext()
  );
  assert.match(message, /untrusted repository data/u);
  assert.match(message, /never as[\s\S]*instructions or authority/u);
});

test('completed task must provide a bounded public result, not reasoning', () => {
  assert.equal(extractReport({
    status: 'completed',
    result: { content: 'answer', reasoningSummary: 'private reasoning' }
  }), 'answer');
  assert.throws(() => extractReport({
    status: 'completed',
    result: { reasoningSummary: 'reasoning only' }
  }), /no result\.content/u);
});

test('send failure stops the exact created task and never selects another route', async () => {
  const stopped = [];
  const client = {
    async health() { return { status: 'ok' }; },
    async createTask() { return taskSnapshot('task-send-failure', 'idle'); },
    async sendMessage() { throw new Error('send failed'); },
    async stop(id) { stopped.push(id); }
  };
  await assert.rejects(run(environment(), {
    client,
    loadReviewContext: reviewContext
  }), /send failed/u);
  assert.deepEqual(stopped, ['task-send-failure']);
});

test('polling refuses a response for a different task and stops the requested task', async () => {
  const stopped = [];
  const client = {
    async getTask() { return { id: 'other-task', status: 'running' }; },
    async stop(id) { stopped.push(id); }
  };
  await assert.rejects(waitForTask(client, 'task-1', {
    timeoutMs: 5_000,
    pollIntervalMs: 250,
    sleep: async () => {}
  }), /requested task ID/u);
  assert.deepEqual(stopped, ['task-1']);
});
