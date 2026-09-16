'use strict';

const path = require('node:path');
const TASK_STATUSES = new Set([
  'idle',
  'running',
  'awaiting_approval',
  'paused',
  'completed',
  'cancelled',
  'failed',
  'step_limit'
]);

class TaskScopeError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TaskScopeError';
  }
}

function assertTaskIdentity(task, expectedTaskID) {
  if (!task || typeof task !== 'object' || Array.isArray(task) ||
      typeof expectedTaskID !== 'string' ||
      !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/u.test(expectedTaskID) ||
      task.id !== expectedTaskID) {
    throw new TaskScopeError('Task response does not match the requested task ID.');
  }
  return task;
}

function normalizeWorkspacePath(value) {
  if (typeof value !== 'string' || value === '' || value.startsWith('//') ||
      !value.startsWith('/') || /\p{Cc}/u.test(value) ||
      Buffer.byteLength(value, 'utf8') > 4_096) {
    throw new TaskScopeError('Workspace path is not a bounded absolute path.');
  }
  let normalized = path.posix.normalize(value);
  if (normalized.length > 1) normalized = normalized.replace(/\/+$/u, '');
  let supplied = value;
  if (supplied.length > 1) supplied = supplied.replace(/\/+$/u, '');
  if (supplied !== normalized) {
    throw new TaskScopeError('Workspace path is not canonical.');
  }
  return normalized;
}

function assertTaskScope(task, expected, {
  verifyMode = true,
  verifyRoute = true
} = {}) {
  if (!task || typeof task !== 'object' || Array.isArray(task)) {
    throw new TaskScopeError('Task response is invalid.');
  }
  const actualWorkspace = normalizeWorkspacePath(task.workspacePath);
  const expectedWorkspace = normalizeWorkspacePath(expected.workspacePath);
  if (actualWorkspace !== expectedWorkspace) {
    throw new TaskScopeError('Task belongs to a different workspace.');
  }
  if (!['plan', 'agent'].includes(task.mode)) {
    throw new TaskScopeError('Task mode is not supported by the v1 task API.');
  }
  if (!TASK_STATUSES.has(task.status)) {
    throw new TaskScopeError('Task status is not supported by the v1 task API.');
  }
  if (!validRouteIdentifier(task.backendID, 256) ||
      !validRouteIdentifier(task.modelID, 512)) {
    throw new TaskScopeError('Task backend/model fields are invalid.');
  }
  if (verifyMode && task.mode !== expected.mode) {
    throw new TaskScopeError('Task mode does not match this command.');
  }
  if (verifyRoute &&
      (task.backendID !== expected.backendID || task.modelID !== expected.modelID)) {
    throw new TaskScopeError('Task backend/model does not match the configured route.');
  }
  return task;
}

function validRouteIdentifier(value, maximumBytes) {
  return typeof value === 'string' && value.trim() !== '' &&
    !/\p{Cc}/u.test(value) && Buffer.byteLength(value, 'utf8') <= maximumBytes;
}

module.exports = {
  TaskScopeError,
  assertTaskIdentity,
  assertTaskScope,
  normalizeWorkspacePath
};
