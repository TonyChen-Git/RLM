'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const { boundedComment, createGitHubComment } = require('../github-client');
const { isSHA, requiredRepository, safeGitEnvironment } = require('../git-context');

test('Git subprocess environment excludes Action and credential secrets', () => {
  const repositoryRoot = path.resolve(__dirname, '../../..');
  const environment = safeGitEnvironment({
    PATH: '/usr/bin:/bin',
    HOME: '/should/not/be/copied',
    INPUT_SERVER_TOKEN: 'server-secret',
    INPUT_GITHUB_TOKEN: 'github-secret',
    GIT_EXTERNAL_DIFF: '/untrusted/helper'
  }, repositoryRoot);
  assert.deepEqual(Object.keys(environment).sort(), [
    'GIT_ATTR_NOSYSTEM',
    'GIT_CONFIG_GLOBAL',
    'GIT_CONFIG_NOSYSTEM',
    'GIT_CONFIG_SYSTEM',
    'GIT_OPTIONAL_LOCKS',
    'GIT_TERMINAL_PROMPT',
    'LANG',
    'LC_ALL',
    'PATH',
    'TMPDIR'
  ]);
  assert.equal(environment.TMPDIR, path.join(repositoryRoot, 'tmp'));
  assert.equal(JSON.stringify(environment).includes('secret'), false);
});

test('Git temporary storage is exactly the canonical repository tmp directory', () => {
  const repositoryRoot = path.resolve(__dirname, '../../..');
  const environment = safeGitEnvironment({ PATH: '/usr/bin:/bin' }, repositoryRoot);
  assert.equal(environment.TMPDIR, path.join(repositoryRoot, 'tmp'));
});

test('Git SHA and repository identifiers are closed and bounded', () => {
  assert.equal(isSHA('a'.repeat(40)), true);
  assert.equal(isSHA('a'.repeat(64)), true);
  assert.equal(isSHA('HEAD'), false);
  assert.equal(requiredRepository('owner/repo'), 'owner/repo');
  assert.throws(() => requiredRepository('../repo'));
});

test('GitHub comment uses one HTTPS request and does not place token in its body', async () => {
  const calls = [];
  await createGitHubComment({
    repository: 'owner/repo',
    issueNumber: 12,
    token: 'github-secret',
    markdown: 'Review body',
    apiURL: 'https://github.example.test/api/v3',
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      return new Response('', { status: 201 });
    }
  });
  assert.equal(calls.length, 1);
  assert.equal(
    calls[0].url,
    'https://github.example.test/api/v3/repos/owner/repo/issues/12/comments'
  );
  assert.equal(calls[0].options.headers.Authorization, 'Bearer github-secret');
  assert.equal(calls[0].options.body.includes('github-secret'), false);
  assert.deepEqual(JSON.parse(calls[0].options.body), { body: 'Review body' });
});

test('oversized comments are truncated on Unicode scalar boundaries', () => {
  const result = boundedComment('🟣'.repeat(20_000));
  assert.ok(Buffer.byteLength(result, 'utf8') <= 64 * 1024);
  assert.match(result, /Comment truncated/u);
});
