'use strict';
// Clicky Bridge: opt-in, token-authenticated, insert-only. Unix socket only; no network listeners.
// Never log document text, terminal text or the token.
const vscode = require('vscode');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const core = require('./bridge-core.js');

const DIR = path.join(os.homedir(), 'Library/Application Support/Clicky/vscode-bridge');
const TOKEN_PATH = path.join(DIR, 'token');
const POLL_MS = 5000;

const busy = new Map(); // Terminal -> running shell executions
const observed = new Set(); // Terminals with a shell-integration event seen by this extension host
const ledger = new core.RequestLedger();
let server = null;
let socketPath = null;
let pollTimer = null;
let focusedAt = 0; // ms epoch of the latest window focus gain

class BridgeError extends Error {
  constructor(code) { super(code); this.code = code; }
}

function readiness(terminal) {
  return core.terminalReadiness({
    shellIntegration: Boolean(terminal.shellIntegration), observed: observed.has(terminal), running: busy.get(terminal) || 0,
  });
}

// The last check before a side effect: every await before it may have outlived the token (revocation)
// or the client's connection (timeout/cancel). Nothing may suspend between this and the edit call.
function commit(ctx) {
  const token = readToken();
  if (!token || !core.tokensEqual(token, ctx.token)) throw new BridgeError('revoked');
  if (!ctx.live()) throw new BridgeError('canceled');
}

// Writes go only to the focused window's active editor, never a merely visible one.
function activeEditorFor(doc) {
  if (!vscode.window.state.focused) throw new BridgeError('focusChanged');
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document !== doc) throw new BridgeError('focusChanged');
  return editor;
}

function ownedWithMode(stat, mode) {
  return stat.uid === process.getuid() && (stat.mode & 0o777) === mode;
}

function isEnabled() {
  try {
    return ownedWithMode(fs.statSync(DIR), 0o700) && ownedWithMode(fs.statSync(TOKEN_PATH), 0o600);
  } catch (_) {
    return false;
  }
}

function readToken() {
  try {
    if (!isEnabled()) return null;
    return fs.readFileSync(TOKEN_PATH, 'utf8').trim();
  } catch (_) {
    return null;
  }
}

function eolName(doc) { return doc.eol === vscode.EndOfLine.CRLF ? 'crlf' : 'lf'; }

function isSupportedScheme(doc) { return doc.uri.scheme === 'file' || doc.uri.scheme === 'untitled'; }

async function terminalSummary() {
  const t = vscode.window.activeTerminal;
  if (!t) return null;
  const pid = await t.processId;
  return {
    id: typeof pid === 'number' ? pid : null,
    name: t.name,
    shellIntegration: Boolean(t.shellIntegration),
    busy: (busy.get(t) || 0) > 0,
    readiness: readiness(t),
    shell: (t.state && t.state.shell) || null,
  };
}

function editorSummary() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || !isSupportedScheme(editor.document)) return null;
  const doc = editor.document;
  return {
    uri: doc.uri.toString(),
    version: doc.version,
    eol: eolName(doc),
    languageId: doc.languageId,
    selections: editor.selections.map((s) => ({
      start: doc.offsetAt(s.start), end: doc.offsetAt(s.end), active: doc.offsetAt(s.active),
    })),
    isUntitled: doc.isUntitled,
  };
}

function findDocument(params) {
  if (typeof params.uri !== 'string') throw new BridgeError('badRequest');
  const doc = vscode.workspace.textDocuments.find((d) => d.uri.toString() === params.uri);
  if (!doc || !isSupportedScheme(doc)) throw new BridgeError('notFound');
  if (params.version !== doc.version) throw new BridgeError('stale');
  return doc;
}

function rangeOf(doc, params, limit) {
  if (!core.validateRange(params.start, params.end, limit)) throw new BridgeError('badRange');
  if (params.end > doc.getText().length) throw new BridgeError('badRange');
  return new vscode.Range(doc.positionAt(params.start), doc.positionAt(params.end));
}

async function methodState() {
  return { focused: vscode.window.state.focused, focusedAt, editor: editorSummary(), terminal: await terminalSummary() };
}

async function methodReadRange(params) {
  const doc = findDocument(params);
  const range = rangeOf(doc, params, core.MAX_READ_UTF16);
  return { text: doc.getText(range) };
}

// Re-reads what the document now holds so a transformed insertion (CRLF) is reported, not assumed.
function verifyInserted(doc, start, text) {
  const read = (length) => doc.getText(new vscode.Range(doc.positionAt(start), doc.positionAt(start + length)));
  if (read(text.length) === text) return { verified: true, normalized: false, length: text.length };
  if (doc.eol === vscode.EndOfLine.CRLF) {
    const crlf = text.replace(/\r?\n/g, '\r\n');
    if (read(crlf.length) === crlf) return { verified: true, normalized: true, length: crlf.length };
  }
  return { verified: false, normalized: false, length: text.length };
}

async function methodReplaceRange(params, ctx) {
  if (typeof params.text !== 'string' || params.text.length > core.MAX_TEXT_UTF16) throw new BridgeError('badRequest');
  if (typeof params.expected !== 'string') throw new BridgeError('badRequest');
  if (params.requireSelection !== undefined && typeof params.requireSelection !== 'boolean') throw new BridgeError('badRequest');
  const doc = findDocument(params);
  const editor = activeEditorFor(doc);
  const range = rangeOf(doc, params, core.MAX_TEXT_UTF16);
  // A forward write is authorized only for the caret/selection the host bound; a restore targets Clicky's own text.
  if (params.requireSelection) {
    const selections = editor.selections.map((s) => ({ start: doc.offsetAt(s.start), end: doc.offsetAt(s.end) }));
    if (!core.selectionMatches(selections, params.start, params.end)) throw new BridgeError('selectionChanged');
  }
  if (doc.getText(range) !== params.expected) throw new BridgeError('sourceChanged');
  commit(ctx);
  const ok = await editor.edit((b) => b.replace(range, params.text), { undoStopBefore: true, undoStopAfter: true });
  if (!ok) return { applied: false };
  const check = verifyInserted(doc, params.start, params.text);
  const end = params.start + check.length;
  const caret = doc.positionAt(end);
  editor.selection = new vscode.Selection(caret, caret);
  return {
    applied: true, verified: check.verified, normalizedLineEndings: check.normalized,
    version: doc.version, start: params.start, end,
  };
}

async function methodInsertTerminal(params, ctx) {
  if (!core.isInsertableTerminalText(params.text)) throw new BridgeError('unsafeText');
  const terminal = vscode.window.activeTerminal;
  if (!terminal) throw new BridgeError('terminalChanged');
  const pid = await terminal.processId;
  if (typeof params.terminalId !== 'number' || pid !== params.terminalId) throw new BridgeError('terminalChanged');
  // Re-read everything after the await: the terminal, focus and readiness may have changed meanwhile.
  if (vscode.window.activeTerminal !== terminal) throw new BridgeError('terminalChanged');
  if (!vscode.window.state.focused) throw new BridgeError('focusChanged');
  if (!terminal.shellIntegration) throw new BridgeError('noShellIntegration');
  const state = readiness(terminal);
  if (state === 'busy') throw new BridgeError('busy');
  if (state !== 'ready') throw new BridgeError('readinessUnknown');
  commit(ctx);
  terminal.sendText(params.text, false);
  // sendText returns nothing: this is delivery to the API, not a read-back of the prompt buffer.
  return { sent: true, verified: false };
}

const METHODS = {
  state: methodState,
  readRange: methodReadRange,
  replaceRange: methodReplaceRange,
  insertTerminal: methodInsertTerminal,
};

async function handleLine(line, live = () => true) {
  let request;
  try { request = core.parseRequest(line); } catch (e) { return core.failure('', e.code || 'badRequest'); }
  const token = readToken();
  if (!token || !core.tokensEqual(token, request.token)) return core.failure(request.id, 'unauthorized');
  if (!Object.prototype.hasOwnProperty.call(METHODS, request.method)) return core.failure(request.id, 'unknownMethod');
  if (!ledger.admit(request.id)) return core.failure(request.id, 'duplicate');
  try {
    return core.response(request.id, await METHODS[request.method](request.params, { token: request.token, live }));
  } catch (e) {
    return core.failure(request.id, e instanceof BridgeError ? e.code : 'internal');
  }
}

function serve(connection) {
  const chunks = [];
  let size = 0;
  let done = false;
  const finish = (payload) => {
    if (done) return;
    done = true;
    if (payload === null) { connection.destroy(); return; }
    connection.end(payload + '\n');
  };
  connection.setTimeout(10000, () => finish(null));
  connection.on('error', () => finish(null));
  // The client never half-closes before reading the reply: end/close means it gave up (timeout or cancel),
  // and a pending handler must not commit a write for a requester that is no longer listening.
  connection.on('end', () => finish(null));
  connection.on('close', () => { done = true; });
  let dispatched = false;
  connection.on('data', (chunk) => {
    // One request per connection: bytes after the first line never re-run it.
    if (done || dispatched) return;
    size += chunk.length;
    if (size > core.MAX_REQUEST_BYTES) { finish(null); return; }
    chunks.push(chunk);
    const all = Buffer.concat(chunks);
    const newline = all.indexOf(10);
    if (newline < 0) return;
    dispatched = true;
    handleLine(all.subarray(0, newline).toString('utf8'), () => !done).then(finish, () => finish(core.failure('', 'internal')));
  });
}

function startServer() {
  if (server) return;
  const target = path.join(DIR, 'vscode-' + process.pid + '.sock');
  try { fs.unlinkSync(target); } catch (_) { /* no stale socket */ }
  const created = net.createServer(serve);
  created.on('error', () => { stopServer(); });
  created.listen(target, () => {
    try { fs.chmodSync(target, 0o600); } catch (_) { /* best effort; dir is 0700 */ }
  });
  server = created;
  socketPath = target;
}

function stopServer() {
  if (server) { try { server.close(); } catch (_) { /* already closed */ } }
  if (socketPath) { try { fs.unlinkSync(socketPath); } catch (_) { /* already gone */ } }
  server = null;
  socketPath = null;
}

function poll() {
  const enabled = isEnabled();
  if (enabled && !server) startServer();
  else if (!enabled && server) stopServer();
}

function activate(context) {
  if (vscode.window.state.focused) focusedAt = Date.now();
  context.subscriptions.push(
    vscode.window.onDidChangeWindowState((state) => { if (state.focused) focusedAt = Date.now(); }),
    vscode.window.onDidChangeTerminalShellIntegration((e) => { observed.add(e.terminal); }),
    vscode.window.onDidStartTerminalShellExecution((e) => {
      observed.add(e.terminal);
      busy.set(e.terminal, (busy.get(e.terminal) || 0) + 1);
    }),
    vscode.window.onDidEndTerminalShellExecution((e) => {
      observed.add(e.terminal);
      busy.set(e.terminal, Math.max(0, (busy.get(e.terminal) || 0) - 1));
    }),
    vscode.window.onDidCloseTerminal((t) => { busy.delete(t); observed.delete(t); }),
  );
  poll();
  pollTimer = setInterval(poll, POLL_MS);
}

function deactivate() {
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = null;
  stopServer();
}

module.exports = { activate, deactivate, _test: { handleLine, serve } };
