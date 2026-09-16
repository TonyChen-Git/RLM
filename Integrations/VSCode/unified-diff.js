'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');

const MAXIMUM_PATCH_BYTES = 4 * 1024 * 1024;
const MAXIMUM_PATCH_FILES = 1_024;
const MAXIMUM_FILE_BYTES = 4 * 1024 * 1024;

class UnifiedDiffError extends Error {
  constructor(message) {
    super(message);
    this.name = 'UnifiedDiffError';
  }
}

function parseUnifiedDiff(patch) {
  if (typeof patch !== 'string' || Buffer.byteLength(patch, 'utf8') > MAXIMUM_PATCH_BYTES) {
    throw new UnifiedDiffError('Diff is missing or exceeds 4 MiB.');
  }
  const lines = patch.split('\n').map((line) => line.endsWith('\r') ? line.slice(0, -1) : line);
  if (lines[lines.length - 1] === '') lines.pop();
  const files = [];
  const seenPaths = new Set();
  let file = null;
  let hunk = null;

  const finishHunk = () => {
    if (!hunk) return;
    const oldCount = hunk.lines.reduce(
      (count, line) => count + (line.kind === 'context' || line.kind === 'remove' ? 1 : 0),
      0
    );
    const newCount = hunk.lines.reduce(
      (count, line) => count + (line.kind === 'context' || line.kind === 'add' ? 1 : 0),
      0
    );
    if (oldCount !== hunk.oldCount || newCount !== hunk.newCount) {
      throw new UnifiedDiffError('Diff hunk line counts do not match its header.');
    }
    file.hunks.push(hunk);
    hunk = null;
  };
  const finishFile = () => {
    if (!file) return;
    finishHunk();
    if (file.binary || file.renameOrCopy) {
      throw new UnifiedDiffError('Binary, rename, and copy patches are not applied by the adapter.');
    }
    if (file.oldPath === undefined || file.newPath === undefined) {
      throw new UnifiedDiffError('Diff file headers are incomplete.');
    }
    if (file.oldPath === null && file.newPath === null) {
      throw new UnifiedDiffError('Diff cannot delete and create /dev/null.');
    }
    if (file.oldPath && file.newPath && file.oldPath !== file.newPath) {
      throw new UnifiedDiffError('Renames must be reviewed and applied manually.');
    }
    if (file.oldPath === null && (file.newFileMode !== '100644' || file.deletedFileMode)) {
      throw new UnifiedDiffError('A new text file must use canonical mode 100644 metadata.');
    }
    if (file.newPath === null && (file.deletedFileMode !== '100644' || file.newFileMode)) {
      throw new UnifiedDiffError('A deleted text file must use canonical mode 100644 metadata.');
    }
    if (file.oldPath !== null && file.newPath !== null &&
        (file.newFileMode || file.deletedFileMode || file.modeChange)) {
      throw new UnifiedDiffError('File-mode changes must be reviewed and applied manually.');
    }
    if (file.hunks.length === 0) {
      throw new UnifiedDiffError('A text patch must contain at least one hunk.');
    }
    const targetPath = file.newPath || file.oldPath;
    if (file.headerOldPath !== targetPath || file.headerNewPath !== targetPath) {
      throw new UnifiedDiffError('Diff paths do not exactly match their file headers.');
    }
    if (seenPaths.has(targetPath)) {
      throw new UnifiedDiffError('Diff contains duplicate changes for one workspace path.');
    }
    seenPaths.add(targetPath);
    files.push(file);
    if (files.length > MAXIMUM_PATCH_FILES) {
      throw new UnifiedDiffError('Diff changes too many files.');
    }
    file = null;
  };

  for (const line of lines) {
    if (line.startsWith('diff --git ')) {
      finishFile();
      const header = /^diff --git a\/([^\s]+) b\/([^\s]+)$/u.exec(line);
      if (!header) {
        throw new UnifiedDiffError('Diff file header uses an unsupported or quoted path.');
      }
      file = {
        headerOldPath: normalizeRelativePath(header[1]),
        headerNewPath: normalizeRelativePath(header[2]),
        oldPath: undefined,
        newPath: undefined,
        hunks: [],
        binary: false,
        renameOrCopy: false,
        newFileMode: null,
        deletedFileMode: null,
        modeChange: false,
        oldNoNewline: false,
        newNoNewline: false
      };
      continue;
    }
    if (!file) {
      if (line.trim() === '') continue;
      throw new UnifiedDiffError('Unexpected content before the first diff header.');
    }
    const match = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?$/u.exec(line);
    if (line === '\\ No newline at end of file') {
      if (!hunk || hunk.lines.length === 0) {
        throw new UnifiedDiffError('No-newline marker has no preceding hunk line.');
      }
      const previous = hunk.lines[hunk.lines.length - 1];
      if (previous.kind === 'remove' || previous.kind === 'context') file.oldNoNewline = true;
      if (previous.kind === 'add' || previous.kind === 'context') file.newNoNewline = true;
      continue;
    }
    if (hunk && !match) {
      const prefix = line[0];
      const kind = prefix === ' ' ? 'context' : prefix === '+' ? 'add' :
        prefix === '-' ? 'remove' : null;
      if (!kind) throw new UnifiedDiffError('Diff hunk contains an unsupported line.');
      hunk.lines.push({ kind, text: line.slice(1) });
      continue;
    }
    if (line.startsWith('Binary files ') || line === 'GIT binary patch') {
      file.binary = true;
      continue;
    }
    if (/^(rename|copy) (from|to) /u.test(line)) {
      file.renameOrCopy = true;
      continue;
    }
    if (line.startsWith('new file mode ')) {
      file.newFileMode = line.slice('new file mode '.length);
      continue;
    }
    if (line.startsWith('deleted file mode ')) {
      file.deletedFileMode = line.slice('deleted file mode '.length);
      continue;
    }
    if (line.startsWith('old mode ') || line.startsWith('new mode ')) {
      file.modeChange = true;
      continue;
    }
    if (line.startsWith('--- ')) {
      finishHunk();
      file.oldPath = parseHeaderPath(line.slice(4), 'a/');
      continue;
    }
    if (line.startsWith('+++ ')) {
      file.newPath = parseHeaderPath(line.slice(4), 'b/');
      continue;
    }
    if (match) {
      if (file.oldPath === undefined || file.newPath === undefined) {
        throw new UnifiedDiffError('Diff hunk appeared before its file headers.');
      }
      finishHunk();
      const coordinates = [
        Number(match[1]),
        match[2] === undefined ? 1 : Number(match[2]),
        Number(match[3]),
        match[4] === undefined ? 1 : Number(match[4])
      ];
      if (!coordinates.every(Number.isSafeInteger)) {
        throw new UnifiedDiffError('Diff hunk coordinates are outside the supported range.');
      }
      if ((coordinates[1] > 0 && coordinates[0] < 1) ||
          (coordinates[3] > 0 && coordinates[2] < 1)) {
        throw new UnifiedDiffError('Diff hunk coordinates are invalid.');
      }
      hunk = {
        oldStart: coordinates[0],
        oldCount: coordinates[1],
        newStart: coordinates[2],
        newCount: coordinates[3],
        lines: []
      };
      continue;
    }
    // Index and mode lines are metadata. Anything that looks like another
    // patch dialect fails closed instead of being partially interpreted.
    if (/^(index |similarity index )/u
      .test(line) || line.trim() === '') {
      continue;
    }
    throw new UnifiedDiffError('Diff contains unsupported file metadata.');
  }
  finishFile();
  if (files.length === 0) throw new UnifiedDiffError('Diff contains no text changes.');
  return files;
}

function parseHeaderPath(value, expectedPrefix) {
  const token = value.split('\t', 1)[0];
  if (token === '/dev/null') return null;
  if (token.startsWith('"') || !token.startsWith(expectedPrefix)) {
    throw new UnifiedDiffError('Quoted or non-canonical diff paths are not supported.');
  }
  return normalizeRelativePath(token.slice(expectedPrefix.length));
}

function normalizeRelativePath(value) {
  if (!value || value.startsWith('/') || value.includes('\\') || value.includes('\0')) {
    throw new UnifiedDiffError('Diff path is not workspace-relative.');
  }
  const components = value.split('/');
  if (components.some((component) => !component || component === '.' || component === '..')) {
    throw new UnifiedDiffError('Diff path contains traversal or non-normalized components.');
  }
  if (components.includes('.git')) {
    throw new UnifiedDiffError('Diff cannot modify Git administrative paths.');
  }
  if (components.some((component) => component.startsWith('._'))) {
    throw new UnifiedDiffError('Diff cannot modify AppleDouble entries.');
  }
  if (Buffer.byteLength(value, 'utf8') > 4_096) {
    throw new UnifiedDiffError('Diff path exceeds its size limit.');
  }
  return components.join('/');
}

function applyFilePatch(source, filePatch) {
  if (typeof source !== 'string' || Buffer.byteLength(source, 'utf8') > MAXIMUM_FILE_BYTES) {
    throw new UnifiedDiffError('Workspace file is not bounded UTF-8 text.');
  }
  if (source.replace(/\r\n/gu, '').includes('\r')) {
    throw new UnifiedDiffError('Workspace file contains unsupported mixed line endings.');
  }
  const newline = source.includes('\r\n') ? '\r\n' : '\n';
  const hadFinalNewline = source.endsWith('\n');
  if (filePatch.oldNoNewline && hadFinalNewline) {
    throw new UnifiedDiffError('Diff newline metadata does not match the workspace file.');
  }
  const normalized = source.endsWith('\n') ? source.slice(0, -1) : source;
  const sourceLines = normalized === '' ? [] : normalized.split('\n').map(
    (line) => line.endsWith('\r') ? line.slice(0, -1) : line
  );
  const output = [];
  let sourceIndex = 0;
  let previousOldEnd = 0;

  for (const hunk of filePatch.hunks) {
    const hunkIndex = hunk.oldStart === 0 ? 0 : hunk.oldStart - 1;
    if (hunkIndex < sourceIndex || hunkIndex < previousOldEnd || hunkIndex > sourceLines.length) {
      throw new UnifiedDiffError('Diff hunks overlap or address a line outside the file.');
    }
    output.push(...sourceLines.slice(sourceIndex, hunkIndex));
    sourceIndex = hunkIndex;
    const newHunkIndex = hunk.newStart === 0 ? 0 : hunk.newStart - 1;
    if (newHunkIndex !== output.length) {
      throw new UnifiedDiffError('Diff new-file coordinates do not match prior hunks.');
    }
    for (const line of hunk.lines) {
      if (line.kind === 'add') {
        output.push(line.text);
        continue;
      }
      if (sourceLines[sourceIndex] !== line.text) {
        throw new UnifiedDiffError('Workspace content changed since this diff was produced.');
      }
      if (line.kind === 'context') output.push(line.text);
      sourceIndex += 1;
    }
    previousOldEnd = hunkIndex + hunk.oldCount;
  }
  output.push(...sourceLines.slice(sourceIndex));

  const touchesEnd = sourceIndex === sourceLines.length;
  const finalNewline = touchesEnd ? !filePatch.newNoNewline : hadFinalNewline;
  const result = output.join(newline) + (finalNewline && output.length > 0 ? newline : '');
  if (Buffer.byteLength(result, 'utf8') > MAXIMUM_FILE_BYTES) {
    throw new UnifiedDiffError('Patched file exceeds 4 MiB.');
  }
  return result;
}

async function buildWorkspaceEdit(vscode, workspaceFolder, patchText) {
  if (!workspaceFolder || workspaceFolder.uri.scheme !== 'file') {
    throw new UnifiedDiffError('Apply Result supports only a local file workspace.');
  }
  const rootPath = await fs.realpath(workspaceFolder.uri.fsPath);
  if (path.resolve(workspaceFolder.uri.fsPath) !== rootPath) {
    throw new UnifiedDiffError('Apply Result refuses a workspace reached through a symbolic link.');
  }
  const patches = parseUnifiedDiff(patchText);
  const planned = [];

  for (const filePatch of patches) {
    const relativePath = filePatch.newPath || filePatch.oldPath;
    const targetPath = path.resolve(rootPath, ...relativePath.split('/'));
    assertInside(rootPath, targetPath);
    const uri = vscode.Uri.file(targetPath);
    if (filePatch.oldPath === null) {
      await assertRealDirectoryChain(rootPath, path.dirname(targetPath));
      const parent = await fs.realpath(path.dirname(targetPath));
      assertInside(rootPath, parent);
      try {
        await fs.lstat(targetPath);
        throw new UnifiedDiffError(`New diff file already exists: ${relativePath}`);
      } catch (error) {
        if (error instanceof UnifiedDiffError) throw error;
        if (error && error.code !== 'ENOENT') throw error;
      }
      planned.push({ kind: 'create', uri, content: applyFilePatch('', filePatch) });
      continue;
    }

    const resolved = await fs.realpath(targetPath);
    assertInside(rootPath, resolved);
    await assertRealDirectoryChain(rootPath, path.dirname(targetPath));
    const metadata = await fs.lstat(targetPath);
    if (!metadata.isFile() || metadata.isSymbolicLink()) {
      throw new UnifiedDiffError(`Diff target is not a regular file: ${relativePath}`);
    }
    const document = await vscode.workspace.openTextDocument(uri);
    const current = document.getText();
    const content = applyFilePatch(current, filePatch);
    if (filePatch.newPath === null) {
      planned.push({ kind: 'delete', uri });
    } else {
      planned.push({ kind: 'replace', uri, document, content });
    }
  }

  const edit = new vscode.WorkspaceEdit();
  for (const change of planned) {
    if (change.kind === 'create') {
      edit.createFile(change.uri, { ignoreIfExists: false, overwrite: false });
      edit.insert(change.uri, new vscode.Position(0, 0), change.content);
    } else if (change.kind === 'delete') {
      edit.deleteFile(change.uri, { recursive: false, ignoreIfNotExists: false });
    } else {
      const lastLine = Math.max(0, change.document.lineCount - 1);
      const end = change.document.lineAt(lastLine).rangeIncludingLineBreak.end;
      edit.replace(change.uri, new vscode.Range(new vscode.Position(0, 0), end), change.content);
    }
  }
  return { edit, fileCount: planned.length, files: planned.map((item) => item.uri.fsPath) };
}

async function assertRealDirectoryChain(root, directory) {
  const relative = path.relative(root, directory);
  if (relative === '') return;
  let cursor = root;
  for (const component of relative.split(path.sep)) {
    cursor = path.join(cursor, component);
    const metadata = await fs.lstat(cursor);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
      throw new UnifiedDiffError('Diff target has a symbolic-link or non-directory parent.');
    }
  }
}

function assertInside(root, candidate) {
  if (candidate !== root && !candidate.startsWith(root + path.sep)) {
    throw new UnifiedDiffError('Diff path resolves outside the workspace.');
  }
}

module.exports = {
  UnifiedDiffError,
  applyFilePatch,
  buildWorkspaceEdit,
  normalizeRelativePath,
  parseUnifiedDiff
};
