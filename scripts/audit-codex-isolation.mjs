#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

// No sign-in, inference, personal profile reads, or raw provider output in this audit.
const executable = process.argv[2] ?? 'codex';
const root = await mkdtemp(join(tmpdir(), 'clicky-codex-audit-'));
const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
  !['CLAUDE_CODE_', 'CODEX_', 'ANTHROPIC_', 'OPENAI_'].some(prefix => key.startsWith(prefix))));
environment.CODEX_HOME = root;
const source = await readFile(fileURLToPath(new URL('../leanring-buddy/TextInput/Core/GuideAgentProfile.swift', import.meta.url)), 'utf8');
const block = source.split('public static let codexOverrides: [String: String] = [')[1]?.split('\n    ]')[0];
if (!block) throw new Error('audit_profile_unreadable');
const overrides = Object.fromEntries([...block.matchAll(/"([a-z0-9_.]+)": "((?:\\.|[^"\\])*)"/g)]
  .map(match => [match[1], JSON.parse('"' + match[2] + '"')]));
if (Object.keys(overrides).length !== [...block.matchAll(/"[^"\n]+"\s*:/g)].length) {
  throw new Error('audit_profile_incomplete');
}
let child;
let lines;
let nextID = 1;
const pending = new Map();

function requireCondition(condition, code) {
  if (!condition) throw new Error(code);
}

function receive(line) {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  clearTimeout(request.timer);
  if (message.error) request.reject(new Error('rpc_rejected_' + request.method.replaceAll('/', '_')));
  else request.resolve(message.result);
}

function rpc(method, params) {
  const id = nextID++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error('rpc_timeout_' + method.replaceAll('/', '_')));
    }, 20000);
    pending.set(id, { resolve, reject, timer, method });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
}

async function auditConfiguration() {
  const { config } = await rpc('config/read', { cwd: root, includeLayers: false });
  requireCondition(config && typeof config === 'object', 'missing_configuration');
  for (const [key, expected] of Object.entries(overrides)) {
    const actual = key.split('.').reduce((value, part) => value?.[part], config);
    requireCondition(JSON.stringify(actual) === expected, 'configuration_mismatch_' + key);
  }
  const servers = Object.keys(config.mcp_servers ?? {});
  const { data } = await rpc('skills/list', { cwds: [root], forceReload: true });
  requireCondition(Array.isArray(data), 'missing_skill_diagnostics');
  const paths = [];
  for (const entry of data) {
    requireCondition(Array.isArray(entry.skills) && Array.isArray(entry.errors) && entry.errors.length === 0,
      'invalid_skill_diagnostics');
    for (const skill of entry.skills) {
      requireCondition(typeof skill.path === 'string', 'missing_skill_source');
      paths.push(skill.path);
    }
  }
  await writeFile(join(root, 'config.toml'), paths.sort().map(path =>
    '[[skills.config]]\npath = ' + JSON.stringify(path) + '\nenabled = false\n').join('\n'), { mode: 0o600 });
  return { servers, paths };
}

async function auditThread(servers, paths, version) {
  const result = await rpc('thread/start', {
    cwd: root, ephemeral: true, sandbox: 'read-only', model: 'gpt-6-luna',
    approvalPolicy: 'untrusted', approvalsReviewer: 'user',
    baseInstructions: 'Only emit structured Clicky presentations. No tools or desktop actions.',
    developerInstructions: 'No tools or desktop actions.',
    config: { mcp_servers: Object.fromEntries(servers.map(name => [name, { enabled: false }])),
      skills: { config: paths.map(path => ({ path, enabled: false })) } },
  });
  requireCondition(Array.isArray(result.instructionSources) && result.instructionSources.length === 0,
    'unexpected_instruction_sources');
  requireCondition(result.thread?.ephemeral === true && typeof result.thread.id === 'string', 'thread_not_ephemeral');
  const { data } = await rpc('skills/list', { cwds: [root], forceReload: true });
  requireCondition(Array.isArray(data) && data.every(entry => Array.isArray(entry.skills)
    && entry.skills.every(skill => skill.enabled === false)), 'skills_not_disabled');
  console.log(JSON.stringify({ configurationDiagnostics: 'passed', discoveredSkills: paths.length,
    disabledMCPServers: servers.length, emptyInstructionSources: true, ephemeralThread: true,
    auditedOverrides: Object.keys(overrides).length, inferenceSubmitted: false }));
  const features = await rpc('experimentalFeature/list', { threadId: result.thread.id, limit: 200 });
  auditRuntimeFeatures(features, version);
  console.log('Runtime isolation diagnostics: passed');
}

function auditRuntimeFeatures(features, version) {
  requireCondition(Array.isArray(features.data), 'missing_runtime_features');
  const featureDiagnostics = Object.entries(overrides).filter(([key]) => key.startsWith('features.'))
    .map(([key, value]) => {
      const feature = features.data.find(feature => feature.name === key.slice(9));
      return { name: key.slice(9), requested: value === 'true',
        enabled: typeof feature?.enabled === 'boolean' ? feature.enabled : null,
        stage: ['stable', 'beta', 'underDevelopment', 'deprecated', 'removed'].includes(feature?.stage) ? feature.stage : null };
    });
  console.log('Runtime feature mismatches: ' + JSON.stringify(featureDiagnostics.filter(feature =>
    feature.enabled !== feature.requested || feature.stage === null)));
  requireCondition(features.nextCursor === null, 'runtime_features_incomplete');
  const shellDisabled = featureDiagnostics.find(feature => feature.name === 'shell_tool')?.enabled === false;
  for (const feature of featureDiagnostics) {
    requireCondition(feature.stage !== null, 'runtime_feature_missing_' + feature.name);
    if (version === '0.162.0' && feature.name === 'unified_exec' && !feature.requested && feature.enabled && shellDisabled) {
      console.log('Known execution selector normalization: unified_exec=true; config/runtime shell_tool=false.');
      continue;
    }
    requireCondition(feature.enabled === feature.requested, 'runtime_feature_mismatch_' + feature.name);
  }
  if (version === '0.162.0') {
    // rust-v0.162.0, c1382380de69521303b416720a52f42d51af6248:
    // core/src/managed_features.rs#L175-L189 normalizes UnifiedExec; tools/spec_plan.rs#L1150-L1198 gates shell tools.
    // models-manager/models.json#L524-L544 sets gpt-6-luna tool_mode=code_mode_only and apply_patch_tool_type=freeform.
    // core/src/tools/mod.rs#L75-L95 honors model tool_mode before Feature::CodeMode;
    // core/src/tools/spec_plan.rs#L1344-L1347 registers patch from model metadata, without an audited disable switch.
    console.log('Source audit: https://github.com/openai/codex/tree/c1382380de69521303b416720a52f42d51af6248');
    console.log('Model tool boundary unproven: catalog requires code_mode_only and freeform patch. No inventory RPC verified.');
    throw new Error('model_tool_boundary_unproven');
  }
}

try {
  const probe = spawnSync(executable, ['--version'], { cwd: root, env: environment, encoding: 'utf8', timeout: 5000 });
  const match = /^codex-cli (\d+\.\d+\.\d+)\s*$/.exec(probe.stdout ?? '');
  requireCondition(probe.status === 0 && match, 'version_probe_failed');
  console.log('Codex version: ' + match[1]);
  const args = ['app-server', '--listen', 'stdio://', '--strict-config',
    ...Object.entries(overrides).sort().flatMap(([key, value]) => ['-c', key + '=' + value])];
  child = spawn(executable, args, { cwd: root, env: environment, stdio: ['pipe', 'pipe', 'ignore'] });
  lines = createInterface({ input: child.stdout });
  lines.on('line', receive);
  await rpc('initialize', { clientInfo: { name: 'clicky-isolation-audit', version: '0.2.0' },
    capabilities: { experimentalApi: false } });
  child.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
  const account = await rpc('account/read', {});
  requireCondition(account.account === null, 'unexpected_authenticated_profile');
  const { servers, paths } = await auditConfiguration();
  await auditThread(servers, paths, match[1]);
  const files = await readdir(root, { recursive: true });
  requireCondition(!files.some(file => String(file).endsWith('.jsonl')), 'unexpected_transcript');
} catch (error) {
  const code = /^[a-z_.]+$/.test(error.message) ? error.message : 'audit_failed';
  console.error('Isolation audit failed: ' + code);
  process.exitCode = 1;
} finally {
  for (const request of pending.values()) clearTimeout(request.timer);
  lines?.close();
  if (child) {
    child.kill();
    await new Promise(resolve => {
      child.once('close', resolve);
      setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 1000).unref();
    });
  }
  await rm(root, { recursive: true, force: true });
}
