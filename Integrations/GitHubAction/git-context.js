'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { TextDecoder } = require('node:util');

const MAXIMUM_EVENT_BYTES = 1024 * 1024;

function loadReviewContext(environment, maximumDiffBytes) {
  const workspace = requiredPath(environment.GITHUB_WORKSPACE, 'GITHUB_WORKSPACE');
  const event = readEvent(environment.GITHUB_EVENT_PATH);
  const repository = requiredRepository(environment.GITHUB_REPOSITORY);
  const baseSHA = optionalSHA(environment.INPUT_BASE_SHA) || event?.pull_request?.base?.sha;
  const headSHA = optionalSHA(environment.INPUT_HEAD_SHA) || event?.pull_request?.head?.sha ||
    optionalSHA(environment.GITHUB_SHA);
  if (!isSHA(baseSHA) || !isSHA(headSHA)) {
    throw new Error('A full hexadecimal base SHA and head SHA are required.');
  }
  const issueOverride = environment.INPUT_ISSUE_NUMBER;
  const pullRequestNumber = positiveInteger(
    issueOverride === undefined || issueOverride === ''
      ? event?.pull_request?.number ?? event?.issue?.number
      : issueOverride,
    'pull request or issue number',
    true
  );
  const canonicalWorkspace = fs.realpathSync(workspace);
  const patch = captureGitDiff(
    canonicalWorkspace,
    baseSHA,
    headSHA,
    maximumDiffBytes,
    environment
  );
  if (patch.trim() === '') throw new Error('The selected base/head range contains no text diff.');
  return {
    workspace: canonicalWorkspace,
    repository,
    baseSHA,
    headSHA,
    pullRequestNumber,
    patch,
    eventName: String(environment.GITHUB_EVENT_NAME || 'unknown').slice(0, 128)
  };
}

function captureGitDiff(workspace, baseSHA, headSHA, maximumBytes, environment = process.env) {
  const canonicalWorkspace = fs.realpathSync(workspace);
  const commonOptions = {
    cwd: canonicalWorkspace,
    encoding: 'buffer',
    maxBuffer: maximumBytes + 1,
    windowsHide: true,
    env: safeGitEnvironment(environment, canonicalWorkspace),
    shell: false
  };
  const topLevel = spawnSync('git', ['rev-parse', '--show-toplevel'], commonOptions);
  if (topLevel.error || topLevel.status !== 0) {
    throw new Error('GITHUB_WORKSPACE is not an accessible Git checkout.');
  }
  const reportedRoot = decodeBounded(topLevel.stdout, 16 * 1024).trim();
  if (fs.realpathSync(reportedRoot) !== canonicalWorkspace) {
    throw new Error('The Git top-level directory must exactly match GITHUB_WORKSPACE.');
  }

  const result = spawnSync('git', [
    '--no-pager', 'diff', '--no-ext-diff', '--no-textconv', '--unified=40',
    baseSHA, headSHA, '--'
  ], commonOptions);
  if (result.error || result.status !== 0) {
    throw new Error('Git could not produce the requested bounded base/head diff.');
  }
  return decodeBounded(result.stdout, maximumBytes);
}

function safeGitEnvironment(source, workspace = process.cwd()) {
  const canonicalWorkspace = fs.realpathSync(workspace);
  const temporaryRoot = prepareTemporaryRoot(canonicalWorkspace);
  return {
    PATH: source.PATH || '/usr/bin:/bin',
    TMPDIR: temporaryRoot,
    GIT_ATTR_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_SYSTEM: '/dev/null',
    GIT_OPTIONAL_LOCKS: '0',
    GIT_TERMINAL_PROMPT: '0',
    LANG: 'C',
    LC_ALL: 'C'
  };
}

function prepareTemporaryRoot(canonicalWorkspace) {
  const temporaryRoot = path.join(canonicalWorkspace, 'tmp');
  try {
    const metadata = fs.lstatSync(temporaryRoot);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
      throw new Error('Repository tmp path must be a real directory, not a link or file.');
    }
    fs.chmodSync(temporaryRoot, 0o700);
  } catch (error) {
    if (!error || error.code !== 'ENOENT') throw error;
    fs.mkdirSync(temporaryRoot, { mode: 0o700 });
  }
  if (fs.realpathSync(temporaryRoot) !== temporaryRoot) {
    throw new Error('Repository tmp directory must remain inside the canonical workspace.');
  }
  return temporaryRoot;
}

function readEvent(eventPath) {
  if (!eventPath) return {};
  const metadata = fs.statSync(eventPath);
  if (!metadata.isFile() || metadata.size > MAXIMUM_EVENT_BYTES) {
    throw new Error('GitHub event payload is missing or exceeds 1 MiB.');
  }
  const data = fs.readFileSync(eventPath);
  try {
    return JSON.parse(decodeBounded(data, MAXIMUM_EVENT_BYTES));
  } catch {
    throw new Error('GitHub event payload is not valid bounded JSON.');
  }
}

function decodeBounded(data, maximumBytes) {
  if (!Buffer.isBuffer(data) || data.length > maximumBytes) {
    throw new Error(`Command output exceeds ${maximumBytes} bytes.`);
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(data);
  } catch {
    throw new Error('Command output is not valid UTF-8 text.');
  }
}

function requiredPath(value, name) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) {
    throw new Error(`${name} must be an absolute path.`);
  }
  return value;
}

function requiredRepository(value) {
  const repository = String(value || '');
  if (!/^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/u.test(repository)) {
    throw new Error('GITHUB_REPOSITORY must be an owner/name pair.');
  }
  return repository;
}

function optionalSHA(value) {
  const result = String(value || '').trim().toLowerCase();
  return result || null;
}

function isSHA(value) {
  return typeof value === 'string' && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u.test(value);
}

function positiveInteger(value, name, optional = false) {
  if ((value === undefined || value === null || value === '') && optional) return null;
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 1) throw new Error(`${name} is invalid.`);
  return number;
}

module.exports = {
  captureGitDiff,
  isSHA,
  loadReviewContext,
  requiredRepository,
  safeGitEnvironment
};
