'use strict';
const test = require('node:test');
const assert = require('node:assert');
const core = require('../bridge-core.js');

const good = { v: 1, id: 'a', token: 't', method: 'state', params: {} };
const code = (fn) => { try { fn(); } catch (e) { return e.code; } return null; };

test('parseRequest accepts valid shape', () => {
  assert.deepStrictEqual(core.parseRequest(JSON.stringify(good)), good);
});

test('parseRequest rejects bad shapes', () => {
  assert.strictEqual(code(() => core.parseRequest('nope')), 'badRequest');
  assert.strictEqual(code(() => core.parseRequest('[]')), 'badRequest');
  assert.strictEqual(code(() => core.parseRequest(JSON.stringify({ ...good, v: 2 }))), 'badVersion');
  assert.strictEqual(code(() => core.parseRequest(JSON.stringify({ ...good, id: 'x'.repeat(65) }))), 'badRequest');
  assert.strictEqual(code(() => core.parseRequest(JSON.stringify({ ...good, id: 3 }))), 'badRequest');
  assert.strictEqual(code(() => core.parseRequest(JSON.stringify({ ...good, token: 1 }))), 'badRequest');
  assert.strictEqual(code(() => core.parseRequest(JSON.stringify({ ...good, method: null }))), 'badRequest');
  assert.strictEqual(code(() => core.parseRequest(JSON.stringify({ ...good, params: [] }))), 'badRequest');
  assert.strictEqual(code(() => core.parseRequest(JSON.stringify({ ...good, params: null }))), 'badRequest');
});

test('tokensEqual', () => {
  assert.ok(core.tokensEqual('abc', 'abc'));
  assert.ok(!core.tokensEqual('abc', 'abd'));
  assert.ok(!core.tokensEqual('abc', 'abcd'));
  assert.ok(!core.tokensEqual('', ''));
  assert.ok(!core.tokensEqual('a', undefined));
});

test('isInsertableTerminalText allows printable shell syntax', () => {
  for (const t of ['ls -la', 'a | b', 'echo "x" \'y\'', 'echo $(pwd)', 'echo `pwd`', 'é 日本 😀', 'a;b&&c']) {
    assert.ok(core.isInsertableTerminalText(t), t);
  }
});

test('isInsertableTerminalText rejects hazards', () => {
  for (const t of ['', 'a\nb', 'a\rb', 'a\tb', 'a\x1bb', 'a\x00b', 'a\x7fb', 'a b', 'a b', 'a\u0085b', 'a\u0090b', 'x\x1b[201~', '\x1b[200~x']) {
    assert.ok(!core.isInsertableTerminalText(t), JSON.stringify(t));
  }
  assert.ok(!core.isInsertableTerminalText(5));
});

test('validateRange', () => {
  assert.ok(core.validateRange(0, 0, 10));
  assert.ok(core.validateRange(2, 12, 10));
  assert.ok(!core.validateRange(2, 13, 10));
  assert.ok(!core.validateRange(-1, 2, 10));
  assert.ok(!core.validateRange(3, 2, 10));
  assert.ok(!core.validateRange(1.5, 2, 10));
  assert.ok(!core.validateRange('1', 2, 10));
});

test('response and failure builders', () => {
  assert.deepStrictEqual(JSON.parse(core.response('i', { a: 1 })), { v: 1, id: 'i', ok: true, result: { a: 1 } });
  assert.deepStrictEqual(JSON.parse(core.failure('i', 'busy')), { v: 1, id: 'i', ok: false, error: 'busy' });
});

test('RequestLedger rejects repeats and stays bounded', () => {
  const ledger = new core.RequestLedger(2);
  assert.ok(ledger.admit('a'));
  assert.ok(!ledger.admit('a'));
  assert.ok(ledger.admit('b'));
  assert.ok(ledger.admit('c'));
  assert.strictEqual(ledger.seen.size, 2);
});

test('terminalReadiness is unknown until observed', () => {
  assert.strictEqual(core.terminalReadiness({ shellIntegration: true, observed: false, running: 0 }), 'unknown');
  assert.strictEqual(core.terminalReadiness({ shellIntegration: false, observed: true, running: 0 }), 'unknown');
  assert.strictEqual(core.terminalReadiness({ shellIntegration: true, observed: true, running: 1 }), 'busy');
  assert.strictEqual(core.terminalReadiness({ shellIntegration: true, observed: true, running: 0 }), 'ready');
});

test('selectionMatches requires one exact selection', () => {
  assert.ok(core.selectionMatches([{ start: 1, end: 3 }], 1, 3));
  assert.ok(!core.selectionMatches([{ start: 1, end: 3 }, { start: 5, end: 5 }], 1, 3));
  assert.ok(!core.selectionMatches([{ start: 2, end: 2 }], 1, 1));
});
