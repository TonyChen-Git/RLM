'use strict';

const MAXIMUM_COMMENT_BYTES = 64 * 1024;

async function createGitHubComment({
  repository,
  issueNumber,
  token,
  markdown,
  apiURL = 'https://api.github.com',
  timeoutMs = 30_000,
  fetchImpl = globalThis.fetch
}) {
  if (!/^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/u.test(repository || '')) {
    throw new Error('GitHub repository is invalid.');
  }
  if (!Number.isSafeInteger(issueNumber) || issueNumber < 1) {
    throw new Error('GitHub issue number is invalid.');
  }
  if (typeof token !== 'string' || token.trim() === '' || token !== token.trim() ||
      /\p{Cc}/u.test(token) || Buffer.byteLength(token, 'utf8') > 16 * 1024) {
    throw new Error('GitHub token is missing or invalid.');
  }
  if (typeof fetchImpl !== 'function') throw new Error('This runtime does not provide fetch().');
  const origin = new URL(apiURL);
  if (origin.protocol !== 'https:' || origin.username || origin.password || origin.search ||
      origin.hash) {
    throw new Error('GitHub API URL must be HTTPS and contain no credentials/query/fragment.');
  }
  const body = boundedComment(markdown);
  const [owner, name] = repository.split('/').map(encodeURIComponent);
  const prefix = origin.pathname.replace(/\/$/u, '');
  const url = new URL(
    `${prefix}/repos/${owner}/${name}/issues/${issueNumber}/comments`,
    origin.origin
  );
  if (url.origin !== origin.origin) throw new Error('GitHub comment URL escaped its origin.');

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, {
      method: 'POST',
      redirect: 'error',
      cache: 'no-store',
      signal: controller.signal,
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        'X-GitHub-Api-Version': '2022-11-28'
      },
      body: JSON.stringify({ body })
    });
    if (!response.ok) {
      throw new Error(`GitHub rejected the review comment (HTTP ${response.status}).`);
    }
    const declared = Number(response.headers.get('content-length'));
    if (Number.isFinite(declared) && declared > 1024 * 1024) {
      throw new Error('GitHub comment response exceeds 1 MiB.');
    }
    // The response body is irrelevant and may contain attacker-controlled
    // content. Cancel it instead of printing or persisting it.
    await response.body?.cancel?.();
  } catch (error) {
    if (controller.signal.aborted) throw new Error('GitHub comment request timed out.');
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function boundedComment(markdown) {
  if (typeof markdown !== 'string' || markdown.trim() === '') {
    throw new Error('LumaChat returned no review text to comment.');
  }
  const suffix = '\n\n_Comment truncated by the LumaChat Action._';
  if (Buffer.byteLength(markdown, 'utf8') <= MAXIMUM_COMMENT_BYTES) return markdown;
  let result = '';
  let bytes = 0;
  const maximum = MAXIMUM_COMMENT_BYTES - Buffer.byteLength(suffix, 'utf8');
  for (const scalar of markdown) {
    const scalarBytes = Buffer.byteLength(scalar, 'utf8');
    if (bytes + scalarBytes > maximum) break;
    result += scalar;
    bytes += scalarBytes;
  }
  return result + suffix;
}

module.exports = { boundedComment, createGitHubComment };
