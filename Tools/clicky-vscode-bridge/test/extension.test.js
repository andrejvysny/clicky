'use strict';
// Exercises the production request handler (extension.js) against a minimal fake `vscode` module:
// authorization at the commit point, focus/selection binding, terminal readiness and replay rejection.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'clicky-bridge-test-'));
process.env.HOME = home;
const dir = path.join(home, 'Library/Application Support/Clicky/vscode-bridge');
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
fs.chmodSync(dir, 0o700);
const tokenPath = path.join(dir, 'token');
const TOKEN = 'a'.repeat(64);
function writeToken(value) { fs.writeFileSync(tokenPath, value, { mode: 0o600 }); fs.chmodSync(tokenPath, 0o600); }

const listeners = {};
const on = (name) => (fn) => { listeners[name] = fn; return { dispose() {} }; };
class Range { constructor(start, end) { this.start = start; this.end = end; } }
class Selection { constructor(anchor, active) { this.start = Math.min(anchor, active); this.end = Math.max(anchor, active); this.active = active; } }
const vscode = {
  EndOfLine: { LF: 1, CRLF: 2 },
  Range, Selection,
  window: {
    state: { focused: true }, activeTextEditor: null, activeTerminal: null, visibleTextEditors: [],
    onDidChangeWindowState: on('window'), onDidChangeTerminalShellIntegration: on('integration'),
    onDidStartTerminalShellExecution: on('start'), onDidEndTerminalShellExecution: on('end'), onDidCloseTerminal: on('close'),
  },
  workspace: { textDocuments: [] },
};
const originalLoad = Module._load;
Module._load = function load(request, ...rest) { return request === 'vscode' ? vscode : originalLoad.call(this, request, ...rest); };
const extension = require('../extension.js');
const { handleLine } = extension._test;

function makeDocument(text, eol = vscode.EndOfLine.LF) {
  const doc = {
    uri: { scheme: 'file', toString: () => 'file:///doc.txt' }, version: 1, eol, languageId: 'plaintext', isUntitled: false, text,
    getText(range) { return range ? this.text.slice(range.start, range.end) : this.text; },
    positionAt(offset) { return offset; }, offsetAt(position) { return position; },
  };
  return doc;
}

function makeEditor(doc, start, end = start) {
  const editor = {
    document: doc, selections: [new Selection(start, end)],
    set selection(value) { this.selections = [value]; },
    async edit(callback) {
      callback({ replace(range, value) {
        const normalized = doc.eol === vscode.EndOfLine.CRLF ? value.replace(/\r?\n/g, '\r\n') : value;
        doc.text = doc.text.slice(0, range.start) + normalized + doc.text.slice(range.end);
      } });
      doc.version += 1;
      return true;
    },
  };
  return editor;
}

function makeTerminal(pid) {
  let release;
  const terminal = {
    name: 'zsh', state: { shell: 'zsh' }, shellIntegration: {}, sent: [],
    processId: Promise.resolve(pid),
    sendText(text, execute) { this.sent.push({ text, execute }); },
    hold() { terminal.processId = new Promise((resolve) => { release = () => resolve(pid); }); },
    release() { release(); },
  };
  return terminal;
}

let nextID = 0;
function request(method, params, id = 'r' + (nextID += 1)) { return JSON.stringify({ v: 1, id, token: TOKEN, method, params }); }
async function call(method, params, options = {}) { return JSON.parse(await handleLine(request(method, params, options.id), options.live)); }

function reset() {
  writeToken(TOKEN);
  vscode.window.state.focused = true;
  vscode.window.activeTextEditor = null; vscode.window.activeTerminal = null; vscode.window.visibleTextEditors = [];
  vscode.workspace.textDocuments = [];
}

test.before(() => { reset(); extension.activate({ subscriptions: [] }); });
test.after(() => { extension.deactivate(); Module._load = originalLoad; fs.rmSync(home, { recursive: true, force: true }); });
test.beforeEach(reset);

function editorFixture(text, caret, eol) {
  const doc = makeDocument(text, eol);
  const editor = makeEditor(doc, caret);
  vscode.workspace.textDocuments = [doc]; vscode.window.visibleTextEditors = [editor]; vscode.window.activeTextEditor = editor;
  return { doc, editor };
}
const insertAt = (offset, text, extra = {}) => ({ uri: 'file:///doc.txt', version: 1, start: offset, end: offset, text, expected: '', ...extra });

test('replaceRange refuses a document that is only visible, not the active editor', async () => {
  const { doc } = editorFixture('hello', 5);
  vscode.window.activeTextEditor = null;
  const reply = await call('replaceRange', insertAt(5, '!', { requireSelection: true }));
  assert.strictEqual(reply.error, 'focusChanged');
  assert.strictEqual(doc.text, 'hello');
});

test('replaceRange refuses when the window lost focus', async () => {
  const { doc } = editorFixture('hello', 5);
  vscode.window.state.focused = false;
  assert.strictEqual((await call('replaceRange', insertAt(5, '!', { requireSelection: true }))).error, 'focusChanged');
  assert.strictEqual(doc.text, 'hello');
});

test('replaceRange with requireSelection refuses a moved caret', async () => {
  const { doc } = editorFixture('hello', 2);
  assert.strictEqual((await call('replaceRange', insertAt(5, '!', { requireSelection: true }))).error, 'selectionChanged');
  assert.strictEqual(doc.text, 'hello');
});

test('replaceRange at the bound caret applies once and reports CRLF normalization', async () => {
  const { doc } = editorFixture('ab', 2, vscode.EndOfLine.CRLF);
  const reply = await call('replaceRange', insertAt(2, 'x\ny', { requireSelection: true }));
  assert.strictEqual(reply.ok, true);
  assert.strictEqual(reply.result.normalizedLineEndings, true);
  assert.strictEqual(reply.result.end - reply.result.start, 4);
  assert.strictEqual(doc.text, 'abx\r\ny');
});

test('replaceRange is not committed after the client disconnected', async () => {
  const { doc } = editorFixture('hello', 5);
  const reply = await call('replaceRange', insertAt(5, '!'), { live: () => false });
  assert.strictEqual(reply.error, 'canceled');
  assert.strictEqual(doc.text, 'hello');
});

function terminalFixture(pid = 77, observe = true) {
  const terminal = makeTerminal(pid);
  vscode.window.activeTerminal = terminal;
  if (observe) listeners.integration({ terminal });
  return terminal;
}

test('insertTerminal refuses when readiness was never observed', async () => {
  const terminal = terminalFixture(77, false);
  assert.strictEqual((await call('insertTerminal', { terminalId: 77, text: 'ls' })).error, 'readinessUnknown');
  assert.deepStrictEqual(terminal.sent, []);
  listeners.integration({ terminal });
  assert.strictEqual((await call('insertTerminal', { terminalId: 77, text: 'ls' })).ok, true);
  assert.deepStrictEqual(terminal.sent, [{ text: 'ls', execute: false }]);
});

test('insertTerminal refuses a running command', async () => {
  const terminal = terminalFixture(78);
  listeners.start({ terminal });
  assert.strictEqual((await call('insertTerminal', { terminalId: 78, text: 'ls' })).error, 'busy');
  listeners.end({ terminal });
  assert.strictEqual((await call('insertTerminal', { terminalId: 78, text: 'ls' })).ok, true);
  assert.strictEqual(terminal.sent.length, 1);
});

test('insertTerminal does not deliver after the token is revoked during the await', async () => {
  const terminal = terminalFixture(79);
  terminal.hold();
  const pending = call('insertTerminal', { terminalId: 79, text: 'ls' });
  fs.unlinkSync(tokenPath);
  terminal.release();
  const reply = await pending;
  assert.strictEqual(reply.ok, false);
  assert.deepStrictEqual(terminal.sent, []);
});

test('insertTerminal does not deliver after the connection timed out during the await', async () => {
  const terminal = terminalFixture(80);
  terminal.hold();
  let live = true;
  const pending = call('insertTerminal', { terminalId: 80, text: 'ls' }, { live: () => live });
  live = false;
  terminal.release();
  assert.strictEqual((await pending).error, 'canceled');
  assert.deepStrictEqual(terminal.sent, []);
});

test('insertTerminal rechecks the active terminal and focus after the await', async () => {
  const terminal = terminalFixture(81);
  terminal.hold();
  const pending = call('insertTerminal', { terminalId: 81, text: 'ls' });
  vscode.window.state.focused = false;
  terminal.release();
  assert.strictEqual((await pending).error, 'focusChanged');
  assert.deepStrictEqual(terminal.sent, []);
});

test('a replayed request id never delivers twice', async () => {
  const terminal = terminalFixture(82);
  assert.strictEqual((await call('insertTerminal', { terminalId: 82, text: 'ls' }, { id: 'same' })).ok, true);
  assert.strictEqual((await call('insertTerminal', { terminalId: 82, text: 'ls' }, { id: 'same' })).error, 'duplicate');
  assert.strictEqual(terminal.sent.length, 1);
});

test('state reports tri-state terminal readiness', async () => {
  terminalFixture(83, false);
  assert.strictEqual((await call('state', {})).result.terminal.readiness, 'unknown');
  listeners.integration({ terminal: vscode.window.activeTerminal });
  assert.strictEqual((await call('state', {})).result.terminal.readiness, 'ready');
});
