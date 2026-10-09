'use strict';
// Pure helpers; must not require('vscode') so they stay testable under plain node.
const crypto = require('crypto');

const PROTOCOL_VERSION = 1;
const MAX_REQUEST_BYTES = 262144;
const MAX_TEXT_UTF16 = 65536;
const MAX_READ_UTF16 = 32768;

function fail(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function parseRequest(line) {
  let value;
  try { value = JSON.parse(line); } catch (_) { throw fail('badRequest'); }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw fail('badRequest');
  if (value.v !== PROTOCOL_VERSION) throw fail('badVersion');
  if (typeof value.id !== 'string' || value.id.length === 0 || value.id.length > 64) throw fail('badRequest');
  if (typeof value.token !== 'string') throw fail('badRequest');
  if (typeof value.method !== 'string') throw fail('badRequest');
  if (value.params === null || typeof value.params !== 'object' || Array.isArray(value.params)) throw fail('badRequest');
  return value;
}

function tokensEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const left = Buffer.from(a, 'utf8');
  const right = Buffer.from(b, 'utf8');
  if (left.length !== right.length || left.length === 0) return false;
  return crypto.timingSafeEqual(left, right);
}

function isInsertableTerminalText(text) {
  if (typeof text !== 'string' || text.length === 0) return false;
  if (text.includes('\x1b[200~') || text.includes('\x1b[201~')) return false;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c <= 0x1f || c === 0x7f || (c >= 0x80 && c <= 0x9f) || c === 0x2028 || c === 0x2029) return false;
  }
  return true;
}

function validateRange(start, end, limit) {
  return Number.isInteger(start) && Number.isInteger(end) && start >= 0 && start <= end && end - start <= limit;
}

function response(id, result) { return JSON.stringify({ v: PROTOCOL_VERSION, id, ok: true, result }); }
function failure(id, code) { return JSON.stringify({ v: PROTOCOL_VERSION, id, ok: false, error: code }); }

module.exports = {
  PROTOCOL_VERSION, MAX_REQUEST_BYTES, MAX_TEXT_UTF16, MAX_READ_UTF16,
  parseRequest, tokensEqual, isInsertableTerminalText, validateRange, response, failure,
};
