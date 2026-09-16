'use strict';

const { isIP } = require('node:net');
const path = require('node:path');

const DEFAULT_SERVER_URL = 'http://127.0.0.1:32189';
const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_MAXIMUM_RESPONSE_BYTES = 4 * 1024 * 1024;
const MAXIMUM_REQUEST_BYTES = 4 * 1024 * 1024;
const MAXIMUM_SSE_EVENT_BYTES = 512 * 1024;
const TASK_EVENT_KINDS = new Set([
  'snapshot',
  'message_delta',
  'reasoning_delta',
  'step',
  'approval_required',
  'diff_changed',
  'state_changed',
  'warning',
  'error',
  'heartbeat'
]);
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

class LumaChatAppServerError extends Error {
  constructor(message, { code = 'APP_SERVER_ERROR', status = null, cause = null } = {}) {
    super(message, cause ? { cause } : undefined);
    this.name = 'LumaChatAppServerError';
    this.code = code;
    this.status = status;
  }
}

class LumaChatAppServerClient {
  constructor({
    baseURL = DEFAULT_SERVER_URL,
    token = '',
    allowRemote = false,
    timeoutMs = DEFAULT_TIMEOUT_MS,
    maximumResponseBytes = DEFAULT_MAXIMUM_RESPONSE_BYTES,
    fetchImpl = globalThis.fetch
  } = {}) {
    if (typeof fetchImpl !== 'function') {
      throw new LumaChatAppServerError('This runtime does not provide fetch().', {
        code: 'UNSUPPORTED_RUNTIME'
      });
    }
    this.baseURL = validateServerURL(baseURL, allowRemote, token);
    this.token = validateToken(token);
    this.timeoutMs = boundedInteger(timeoutMs, 500, 120_000, 'timeoutMs');
    this.maximumResponseBytes = boundedInteger(
      maximumResponseBytes,
      1_024,
      8 * 1024 * 1024,
      'maximumResponseBytes'
    );
    this.fetchImpl = fetchImpl;
  }

  async health() {
    const value = await this.#requestJSON('GET', '/v1/health');
    if (!value || typeof value !== 'object' || value.status !== 'ok') {
      throw new LumaChatAppServerError('LumaChat App Server returned an invalid health response.', {
        code: 'PROTOCOL_VIOLATION'
      });
    }
    if (value.apiVersion !== 'v1') {
      throw new LumaChatAppServerError('LumaChat App Server does not support API v1.', {
        code: 'UNSUPPORTED_API'
      });
    }
    return value;
  }

  listTasks() {
    return this.#requestJSON('GET', '/v1/tasks');
  }

  createTask({ mode, workspacePath, backendID, modelID, title } = {}) {
    const body = {
      mode: requiredEnum(mode, ['plan', 'agent'], 'mode'),
      workspacePath: requiredAbsolutePath(workspacePath),
      backendID: requiredString(backendID, 'backendID', 256),
      modelID: requiredString(modelID, 'modelID', 512)
    };
    if (title !== undefined && title !== '') {
      body.title = requiredString(title, 'title', 512);
    }
    return this.#requestJSON('POST', '/v1/tasks', body);
  }

  getTask(taskID) {
    return this.#requestJSON('GET', taskPath(taskID));
  }

  async sendMessage(taskID, { content, metadata } = {}) {
    const body = {
      content: requiredString(content, 'content', 1024 * 1024, true)
    };
    if (metadata !== undefined) {
      if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
        throw invalidArgument('metadata must be an object.');
      }
      body.metadata = metadata;
    }
    const expectedTaskID = requiredOpaqueID(taskID, 'taskID');
    const value = await this.#requestJSON('POST', `${taskPath(expectedTaskID)}/messages`, body);
    return validateAcceptedOperation(value, expectedTaskID);
  }

  async approve(taskID, approvalID, decision) {
    const expectedTaskID = requiredOpaqueID(taskID, 'taskID');
    const value = await this.#requestJSON('POST', `${taskPath(expectedTaskID)}/approve`, {
      approvalID: requiredOpaqueID(approvalID, 'approvalID'),
      decision: requiredEnum(decision, ['allowOnce', 'allowForTask', 'deny'], 'decision')
    });
    return validateAcceptedOperation(value, expectedTaskID);
  }

  async pause(taskID) {
    return this.#control(taskID, 'pause', {});
  }

  async resume(taskID, { content, metadata } = {}) {
    const body = {};
    if (content !== undefined && content !== null) {
      body.content = requiredString(content, 'content', 1024 * 1024, true);
    }
    if (metadata !== undefined) {
      if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
        throw invalidArgument('metadata must be an object.');
      }
      body.metadata = metadata;
    }
    return this.#control(taskID, 'resume', body);
  }

  async stop(taskID) {
    return this.#control(taskID, 'stop', {});
  }

  async diff(taskID) {
    const expectedTaskID = requiredOpaqueID(taskID, 'taskID');
    const response = await this.#fetch('GET', `${taskPath(expectedTaskID)}/diff`, undefined, {
      accept: 'application/json'
    });
    const contentType = response.headers.get('content-type') || '';
    const data = await readBoundedResponse(response, this.maximumResponseBytes);
    if (!response.ok) {
      throw responseError(response.status, data, contentType);
    }
    if (!contentType.toLowerCase().includes('json')) {
      throw new LumaChatAppServerError('Task diff response is not JSON.', {
        code: 'PROTOCOL_VIOLATION',
        status: response.status
      });
    }
    const value = decodeJSON(data);
    if (!value || typeof value !== 'object' || value.taskID !== expectedTaskID ||
        typeof value.diff !== 'string' || !Array.isArray(value.changedPaths) ||
        typeof value.truncated !== 'boolean' || typeof value.generatedAt !== 'string') {
      throw new LumaChatAppServerError('Task diff JSON does not match the requested task.', {
        code: 'PROTOCOL_VIOLATION'
      });
    }
    if (value.truncated) {
      throw new LumaChatAppServerError('Task diff is truncated and cannot be reviewed or applied safely.', {
        code: 'TRUNCATED_DIFF'
      });
    }
    if (value.changedPaths.length > 1_024 || value.changedPaths.some((item) =>
      typeof item !== 'string' || item === '' || item.includes('\0') ||
      Buffer.byteLength(item, 'utf8') > 4_096)) {
      throw new LumaChatAppServerError('Task diff changedPaths are invalid.', {
        code: 'PROTOCOL_VIOLATION'
      });
    }
    return value;
  }

  async *events(taskID, { signal, after } = {}) {
    const expectedTaskID = requiredOpaqueID(taskID, 'taskID');
    const cursor = after === undefined
      ? ''
      : `?after=${boundedInteger(after, 0, Number.MAX_SAFE_INTEGER, 'after')}`;
    const stream = await this.#fetch('GET', `${taskPath(expectedTaskID)}/events${cursor}`, undefined, {
      accept: 'text/event-stream',
      signal,
      streaming: true
    });
    const response = stream.response;
    if (!response.ok) {
      try {
        const data = await readBoundedResponse(response, this.maximumResponseBytes);
        throw responseError(response.status, data, response.headers.get('content-type') || '');
      } finally {
        stream.close();
      }
    }
    if (!(response.headers.get('content-type') || '').toLowerCase().startsWith('text/event-stream')) {
      stream.close();
      throw new LumaChatAppServerError('Task event response is not an SSE stream.', {
        code: 'PROTOCOL_VIOLATION',
        status: response.status
      });
    }
    if (!response.body || typeof response.body.getReader !== 'function') {
      stream.close();
      throw new LumaChatAppServerError('Task event stream is unavailable.', {
        code: 'PROTOCOL_VIOLATION'
      });
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder('utf-8', { fatal: true });
    let buffer = '';
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        if (Buffer.byteLength(buffer, 'utf8') > MAXIMUM_SSE_EVENT_BYTES * 2) {
          throw new LumaChatAppServerError('Task event stream exceeded its buffer limit.', {
            code: 'RESPONSE_TOO_LARGE'
          });
        }
        let boundary;
        while ((boundary = eventBoundary(buffer)) !== null) {
          const block = buffer.slice(0, boundary.index);
          buffer = buffer.slice(boundary.index + boundary.length);
          if (Buffer.byteLength(block, 'utf8') > MAXIMUM_SSE_EVENT_BYTES) {
            throw new LumaChatAppServerError('One task event exceeded its size limit.', {
              code: 'RESPONSE_TOO_LARGE'
            });
          }
          const event = decodeSSEBlock(block);
          if (event) {
            assertEventTask(event, expectedTaskID);
            yield event;
          }
        }
      }
      buffer += decoder.decode();
      if (buffer.trim()) {
        const event = decodeSSEBlock(buffer);
        if (event) {
          assertEventTask(event, expectedTaskID);
          yield event;
        }
      }
    } catch (error) {
      if (error && error.name === 'AbortError') {
        throw new LumaChatAppServerError('Task event stream was cancelled.', {
          code: 'CANCELLED',
          cause: error
        });
      }
      if (error instanceof LumaChatAppServerError) throw error;
      throw new LumaChatAppServerError('Task event stream failed.', {
        code: 'UNAVAILABLE',
        cause: error
      });
    } finally {
      reader.releaseLock();
      stream.close();
    }
  }

  async #requestJSON(method, path, body) {
    const response = await this.#fetch(method, path, body, {
      accept: 'application/json'
    });
    const contentType = response.headers.get('content-type') || '';
    const data = await readBoundedResponse(response, this.maximumResponseBytes);
    if (!response.ok) throw responseError(response.status, data, contentType);
    if (response.status === 204 || data.length === 0) return null;
    if (!contentType.toLowerCase().includes('json')) {
      throw new LumaChatAppServerError('LumaChat App Server returned non-JSON data.', {
        code: 'PROTOCOL_VIOLATION',
        status: response.status
      });
    }
    return decodeJSON(data);
  }

  async #control(taskID, operation, body) {
    const expectedTaskID = requiredOpaqueID(taskID, 'taskID');
    const value = await this.#requestJSON(
      'POST',
      `${taskPath(expectedTaskID)}/${operation}`,
      body
    );
    return validateAcceptedOperation(value, expectedTaskID);
  }

  async #fetch(method, path, body, options) {
    const url = new URL(path, this.baseURL);
    if (url.origin !== this.baseURL.origin) {
      throw new LumaChatAppServerError('App Server request escaped its configured origin.', {
        code: 'INVALID_CONFIGURATION'
      });
    }
    const headers = { Accept: options.accept };
    let encodedBody;
    if (body !== undefined) {
      encodedBody = JSON.stringify(body);
      if (Buffer.byteLength(encodedBody, 'utf8') > MAXIMUM_REQUEST_BYTES) {
        throw invalidArgument('Request body exceeds 4 MiB.');
      }
      headers['Content-Type'] = 'application/json';
    }
    if (this.token) headers.Authorization = `Bearer ${this.token}`;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    const detach = forwardAbort(options.signal, controller);
    let keepStreamOpen = false;
    try {
      const response = await this.fetchImpl(url, {
        method,
        headers,
        body: encodedBody,
        redirect: 'error',
        cache: 'no-store',
        signal: controller.signal
      });
      const declaredLength = Number(response.headers.get('content-length'));
      if (Number.isFinite(declaredLength) && declaredLength > this.maximumResponseBytes) {
        controller.abort();
        throw new LumaChatAppServerError('App Server response exceeds its size limit.', {
          code: 'RESPONSE_TOO_LARGE',
          status: response.status
        });
      }
      if (options.streaming) {
        clearTimeout(timeout);
        keepStreamOpen = true;
        return {
          response,
          close() {
            detach();
            controller.abort();
          }
        };
      }
      return response;
    } catch (error) {
      if (error instanceof LumaChatAppServerError) throw error;
      if (controller.signal.aborted) {
        throw new LumaChatAppServerError('LumaChat App Server request timed out or was cancelled.', {
          code: 'TIMEOUT',
          cause: error
        });
      }
      throw new LumaChatAppServerError('LumaChat App Server is unavailable.', {
        code: 'UNAVAILABLE',
        cause: error
      });
    } finally {
      if (!keepStreamOpen) {
        clearTimeout(timeout);
        detach();
      }
    }
  }
}

function validateServerURL(value, allowRemote, token) {
  let url;
  try {
    const raw = value === undefined || value === null || value === ''
      ? DEFAULT_SERVER_URL
      : value;
    if (typeof raw !== 'string' || raw !== raw.trim()) throw new Error('invalid URL text');
    url = new URL(raw);
  } catch (error) {
    throw new LumaChatAppServerError('App Server URL is invalid.', {
      code: 'INVALID_CONFIGURATION',
      cause: error
    });
  }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
      url.search || url.hash || (url.pathname !== '/' && url.pathname !== '')) {
    throw new LumaChatAppServerError(
      'App Server URL must be an HTTP(S) origin without credentials, path, query, or fragment.',
      { code: 'INVALID_CONFIGURATION' }
    );
  }
  const loopback = isLoopbackHostname(url.hostname);
  if (!loopback && !allowRemote) {
    throw new LumaChatAppServerError(
      'Non-loopback App Server URLs require the explicit allowRemote setting.',
      { code: 'REMOTE_ENDPOINT_REFUSED' }
    );
  }
  if (!loopback && url.protocol !== 'https:') {
    throw new LumaChatAppServerError('A remote App Server must use HTTPS.', {
      code: 'REMOTE_ENDPOINT_REFUSED'
    });
  }
  if (!loopback && !String(token || '').trim()) {
    throw new LumaChatAppServerError('A remote App Server requires a Bearer token.', {
      code: 'MISSING_TOKEN'
    });
  }
  url.pathname = '/';
  return url;
}

function isLoopbackHostname(value) {
  const hostname = String(value).toLowerCase().replace(/^\[|\]$/g, '');
  if (hostname === 'localhost' || hostname === '::1') return true;
  if (isIP(hostname) === 4) return hostname.split('.')[0] === '127';
  return false;
}

function validateToken(value) {
  if (typeof value !== 'string' || Buffer.byteLength(value, 'utf8') < 32 ||
      Buffer.byteLength(value, 'utf8') > 512 || /\p{Cc}/u.test(value)) {
    throw new LumaChatAppServerError('Bearer token must contain 32-512 non-control UTF-8 bytes.', {
      code: 'INVALID_CONFIGURATION'
    });
  }
  return value;
}

function boundedInteger(value, minimum, maximum, name) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw invalidArgument(`${name} must be an integer in ${minimum}...${maximum}.`);
  }
  return number;
}

function requiredString(value, name, maximumBytes, allowNewlines = false) {
  const invalidControl = allowNewlines
    ? /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/u
    : /\p{Cc}/u;
  if (typeof value !== 'string' || value.trim() === '' || value.includes('\0') ||
      invalidControl.test(value) || Buffer.byteLength(value, 'utf8') > maximumBytes) {
    throw invalidArgument(`${name} is missing or invalid.`);
  }
  return value;
}

function requiredAbsolutePath(value) {
  const result = requiredString(value, 'workspacePath', 4_096);
  const normalized = path.posix.normalize(result);
  const supplied = result.length > 1 ? result.replace(/\/+$/u, '') : result;
  if (!result.startsWith('/') || result.startsWith('//') || supplied !== normalized) {
    throw invalidArgument('workspacePath must be an absolute normalized path.');
  }
  return normalized;
}

function requiredEnum(value, allowed, name) {
  if (!allowed.includes(value)) {
    throw invalidArgument(`${name} must be one of: ${allowed.join(', ')}.`);
  }
  return value;
}

function requiredOpaqueID(value, name) {
  const result = requiredString(value, name, 128);
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/u.test(result)) {
    throw invalidArgument(`${name} contains unsupported characters.`);
  }
  return result;
}

function taskPath(taskID) {
  return `/v1/tasks/${encodeURIComponent(requiredOpaqueID(taskID, 'taskID'))}`;
}

function validateAcceptedOperation(value, expectedTaskID) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      value.taskID !== expectedTaskID || value.accepted !== true ||
      !TASK_STATUSES.has(value.status) ||
      typeof value.requestID !== 'string' ||
      !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/u.test(value.requestID)) {
    throw new LumaChatAppServerError(
      'App Server acknowledgement does not match the requested task.',
      { code: 'PROTOCOL_VIOLATION' }
    );
  }
  return value;
}

function assertEventTask(event, expectedTaskID) {
  if (event.data.taskID !== expectedTaskID) {
    throw new LumaChatAppServerError('Task event belongs to a different task.', {
      code: 'PROTOCOL_VIOLATION'
    });
  }
}

function invalidArgument(message) {
  return new LumaChatAppServerError(message, { code: 'INVALID_ARGUMENT' });
}

function forwardAbort(signal, controller) {
  if (!signal) return () => {};
  const abort = () => controller.abort();
  if (signal.aborted) abort();
  else signal.addEventListener('abort', abort, { once: true });
  return () => signal.removeEventListener('abort', abort);
}

async function readBoundedResponse(response, maximumBytes) {
  const reader = response.body?.getReader?.();
  if (!reader) {
    const data = Buffer.from(await response.arrayBuffer());
    if (data.length > maximumBytes) throw responseTooLarge(response.status);
    return data;
  }
  const chunks = [];
  let count = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    count += value.byteLength;
    if (count > maximumBytes) {
      await reader.cancel();
      throw responseTooLarge(response.status);
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks, count);
}

function responseTooLarge(status) {
  return new LumaChatAppServerError('App Server response exceeds its size limit.', {
    code: 'RESPONSE_TOO_LARGE',
    status
  });
}

function decodeUTF8(data) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(data);
  } catch (error) {
    throw new LumaChatAppServerError('App Server returned invalid UTF-8.', {
      code: 'PROTOCOL_VIOLATION',
      cause: error
    });
  }
}

function decodeJSON(data) {
  try {
    return JSON.parse(decodeUTF8(data));
  } catch (error) {
    if (error instanceof LumaChatAppServerError) throw error;
    throw new LumaChatAppServerError('App Server returned invalid JSON.', {
      code: 'PROTOCOL_VIOLATION',
      cause: error
    });
  }
}

function responseError(status, data, contentType) {
  let code = 'HTTP_ERROR';
  let message = `LumaChat App Server rejected the request (HTTP ${status}).`;
  if (contentType.toLowerCase().includes('json') && data.length) {
    try {
      const value = JSON.parse(decodeUTF8(data));
      const candidateCode = value?.error?.code ?? value?.code;
      if (typeof candidateCode === 'string' && /^[A-Za-z0-9_.-]{1,64}$/u.test(candidateCode)) {
        code = candidateCode;
      }
    } catch {
      // Do not surface arbitrary or malformed response bodies in CI/editor logs.
    }
  }
  return new LumaChatAppServerError(message, { code, status });
}

function eventBoundary(buffer) {
  const lf = buffer.indexOf('\n\n');
  const crlf = buffer.indexOf('\r\n\r\n');
  if (lf < 0 && crlf < 0) return null;
  if (lf >= 0 && (crlf < 0 || lf < crlf)) return { index: lf, length: 2 };
  return { index: crlf, length: 4 };
}

function decodeSSEBlock(block) {
  let event = 'message';
  let id = null;
  const data = [];
  for (const line of block.split(/\r?\n/u)) {
    if (!line || line.startsWith(':')) continue;
    const separator = line.indexOf(':');
    const field = separator < 0 ? line : line.slice(0, separator);
    let value = separator < 0 ? '' : line.slice(separator + 1);
    if (value.startsWith(' ')) value = value.slice(1);
    if (field === 'event') event = value;
    else if (field === 'id') id = value;
    else if (field === 'data') data.push(value);
  }
  if (data.length === 0) return null;
  const raw = data.join('\n');
  let value;
  try {
    value = JSON.parse(raw);
  } catch (error) {
    throw new LumaChatAppServerError('Task event data is not valid JSON.', {
      code: 'PROTOCOL_VIOLATION',
      cause: error
    });
  }
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      !Number.isSafeInteger(value.sequence) || value.sequence < 1 ||
      typeof value.taskID !== 'string' || !TASK_EVENT_KINDS.has(value.kind) ||
      typeof value.timestamp !== 'string' || !Object.hasOwn(value, 'payload') ||
      event !== value.kind || id !== String(value.sequence)) {
    throw new LumaChatAppServerError('Task event does not match the v1 event envelope.', {
      code: 'PROTOCOL_VIOLATION'
    });
  }
  return { event, id, data: value };
}

module.exports = {
  DEFAULT_SERVER_URL,
  LumaChatAppServerClient,
  LumaChatAppServerError,
  isLoopbackHostname,
  validateServerURL
};
