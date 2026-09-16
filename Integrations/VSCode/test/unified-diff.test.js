'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  UnifiedDiffError,
  applyFilePatch,
  parseUnifiedDiff
} = require('../unified-diff');

test('parses and applies an exact-context text modification', () => {
  const patch = [
    'diff --git a/Sources/A.swift b/Sources/A.swift',
    'index 1111111..2222222 100644',
    '--- a/Sources/A.swift',
    '+++ b/Sources/A.swift',
    '@@ -1,3 +1,3 @@',
    ' first',
    '-old',
    '+new',
    ' last',
    ''
  ].join('\n');
  const files = parseUnifiedDiff(patch);
  assert.equal(files.length, 1);
  assert.equal(files[0].newPath, 'Sources/A.swift');
  assert.equal(applyFilePatch('first\nold\nlast\n', files[0]), 'first\nnew\nlast\n');
});

test('supports bounded text creation and deletion', () => {
  const create = parseUnifiedDiff([
    'diff --git a/new.txt b/new.txt',
    'new file mode 100644',
    '--- /dev/null',
    '+++ b/new.txt',
    '@@ -0,0 +1,2 @@',
    '+one',
    '+two',
    ''
  ].join('\n'))[0];
  assert.equal(applyFilePatch('', create), 'one\ntwo\n');

  const remove = parseUnifiedDiff([
    'diff --git a/old.txt b/old.txt',
    'deleted file mode 100644',
    '--- a/old.txt',
    '+++ /dev/null',
    '@@ -1,2 +0,0 @@',
    '-one',
    '-two',
    ''
  ].join('\n'))[0];
  assert.equal(applyFilePatch('one\ntwo\n', remove), '');
});

test('refuses stale context instead of partially applying a patch', () => {
  const file = parseUnifiedDiff([
    'diff --git a/a.txt b/a.txt',
    '--- a/a.txt',
    '+++ b/a.txt',
    '@@ -1 +1 @@',
    '-expected',
    '+replacement',
    ''
  ].join('\n'))[0];
  assert.throws(
    () => applyFilePatch('changed\n', file),
    (error) => error instanceof UnifiedDiffError && /changed since/u.test(error.message)
  );
});

test('refuses Git metadata, traversal, AppleDouble, binary, and rename patches', () => {
  const unsafe = [
    ['--- a/.git/config', '+++ b/.git/config'],
    ['--- a/../outside', '+++ b/../outside'],
    ['--- a/cache/._entry', '+++ b/cache/._entry']
  ];
  for (const [oldHeader, newHeader] of unsafe) {
    assert.throws(() => parseUnifiedDiff([
      'diff --git a/a b/a', oldHeader, newHeader,
      '@@ -1 +1 @@', '-old', '+new', ''
    ].join('\n')), UnifiedDiffError);
  }
  assert.throws(() => parseUnifiedDiff([
    'diff --git a/a.png b/a.png',
    'Binary files a/a.png and b/a.png differ',
    ''
  ].join('\n')), UnifiedDiffError);
  assert.throws(() => parseUnifiedDiff([
    'diff --git a/old.txt b/new.txt',
    'similarity index 100%',
    'rename from old.txt',
    'rename to new.txt',
    ''
  ].join('\n')), UnifiedDiffError);
});

test('refuses path-header mismatches, duplicate targets, and mode changes', () => {
  assert.throws(() => parseUnifiedDiff([
    'diff --git a/a.txt b/a.txt',
    '--- a/b.txt',
    '+++ b/b.txt',
    '@@ -1 +1 @@',
    '-old',
    '+new',
    ''
  ].join('\n')), /file headers/u);

  const one = [
    'diff --git a/a.txt b/a.txt',
    '--- a/a.txt',
    '+++ b/a.txt',
    '@@ -1 +1 @@',
    '-old',
    '+new'
  ];
  assert.throws(() => parseUnifiedDiff([...one, ...one, ''].join('\n')), /duplicate/u);

  assert.throws(() => parseUnifiedDiff([
    'diff --git a/a.txt b/a.txt',
    'old mode 100644',
    'new mode 100755',
    '--- a/a.txt',
    '+++ b/a.txt',
    '@@ -1 +1 @@',
    '-old',
    '+new',
    ''
  ].join('\n')), /mode changes/u);
});
