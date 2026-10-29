import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const sim = join(root, 'scripts/sim/sim.py');
const reporter = join(root, 'scripts/ci/runtime_failure_summary.py');

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'sim-timeout-'));
  writeFileSync(join(dir, 'xcrun'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(process.env.FAKE_STARTED, 'ready');\nif (process.env.FAKE_MODE === 'timeout') setTimeout(() => {}, 5000);\nelse process.exit(process.env.FAKE_MODE === 'error' ? 73 : 0);\n`, { mode: 0o755 });
  const summary = join(dir, 'runtime-phase-inspector.md');
  const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`, FAKE_MODE: 'timeout', FAKE_STARTED: join(dir, 'started'),
    CKSIM_RECORD_TIMEOUT_OPERATIONS: '1', GITHUB_STEP_SUMMARY: summary };
  return { dir, summary, env, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

function call(env: NodeJS.ProcessEnv, operation = 'launch') {
  const timeout = env.FAKE_MODE === 'timeout' ? '0.2' : '3';
  return spawnSync('python3', [sim, 'call', '', timeout, 'xcrun', 'simctl', operation, 'private-device', 'private-bundle'],
    { cwd: root, env, encoding: 'utf8', timeout: 10_000 });
}

test('timeout records a safe operation and propagates to the phase summary', () => {
  const f = fixture();
  try {
    const result = call(f.env);
    assert.equal(result.status, 124, result.stderr);
    const receipt = readFileSync(f.summary, 'utf8');
    assert.match(receipt, /`measurement:simctl-timeout`: launch/);
    assert.doesNotMatch(receipt, /private-device|private-bundle/);
    const report = spawnSync('python3', [reporter], { cwd: root, encoding: 'utf8', timeout: 10_000,
      env: { ...f.env, RUNNER_TEMP: f.dir, GITHUB_STEP_SUMMARY: join(f.dir, 'final'), RUNTIME_PHASE_OUTCOMES: '{"inspector":"failure"}' } });
    assert.equal(report.status, 0, report.stderr);
    assert.match(report.stdout, /observed simctl timeouts: `launch`/);
    assert.doesNotMatch(report.stdout, /private-device|private-bundle/);
  } finally { f.cleanup(); }
});

test('disabled, unknown, successful and non-timeout operations are not measured', () => {
  for (const [enabled, operation, mode, status] of [['0', 'launch', 'timeout', 124], ['1', 'secret-operation', 'timeout', 124], ['1', 'launch', 'success', 0], ['1', 'launch', 'error', 73]] as const) {
    const f = fixture();
    try {
      const result = call({ ...f.env, CKSIM_RECORD_TIMEOUT_OPERATIONS: enabled, FAKE_MODE: mode }, operation);
      assert.equal(result.status, status, result.stderr);
      const receipt = existsSync(f.summary) ? readFileSync(f.summary, 'utf8') : '';
      assert.doesNotMatch(receipt, /measurement:simctl-timeout/);
    } finally { f.cleanup(); }
  }
});

test('unwritable summary does not change the timeout result', () => {
  const f = fixture();
  try { assert.equal(call({ ...f.env, GITHUB_STEP_SUMMARY: f.dir }).status, 124); }
  finally { f.cleanup(); }
});

test('cancellation remains visible and does not record a timeout', { timeout: 10_000 }, async () => {
  const f = fixture();
  let child: ReturnType<typeof spawn> | undefined;
  try {
    child = spawn('python3', [sim, 'call', '', '5', 'xcrun', 'simctl', 'launch'], { cwd: root, env: f.env, stdio: 'ignore' });
    const exited = once(child, 'exit');
    const deadline = Date.now() + 3000;
    while (!existsSync(f.env.FAKE_STARTED) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
    assert.ok(existsSync(f.env.FAKE_STARTED), 'fake simulator did not start');
    child.kill('SIGTERM');
    const [code] = await exited;
    assert.equal(code, 143);
    const receipt = existsSync(f.summary) ? readFileSync(f.summary, 'utf8') : '';
    assert.doesNotMatch(receipt, /measurement:simctl-timeout/);
  } finally { child?.kill('SIGTERM'); f.cleanup(); }
});

test('cancellation during measurement reporting propagates', { timeout: 10_000 }, async () => {
  const f = fixture();
  let child: ReturnType<typeof spawn> | undefined;
  try {
    const fifo = join(f.dir, 'blocked-summary');
    assert.equal(spawnSync('mkfifo', [fifo]).status, 0);
    child = spawn('python3', [sim, 'call', '', '0.2', 'xcrun', 'simctl', 'launch'],
      { cwd: root, env: { ...f.env, GITHUB_STEP_SUMMARY: fifo }, stdio: ['ignore', 'ignore', 'pipe'] });
    const exited = once(child, 'exit');
    let diagnostics = '';
    assert.ok(child.stderr);
    child.stderr.setEncoding('utf8');
    for await (const chunk of child.stderr) {
      diagnostics += chunk;
      if (diagnostics.includes('measurement:simctl-timeout')) { child.kill('SIGTERM'); break; }
    }
    const [code] = await exited;
    assert.equal(code, 143);
  } finally { child?.kill('SIGTERM'); f.cleanup(); }
});

test('runtime runner preserves the timeout for the phase report', () => {
  const f = fixture();
  try {
    const runner = join(root, 'Tests/RuntimeEvents/run.py');
    const invoke = "import runpy; runpy.run_path(" + JSON.stringify(runner) + ")[" + JSON.stringify('run') + "]('xcrun','simctl','launch','private-device','private-bundle',timeout=.2)";
    const result = spawnSync('python3', ['-c', invoke], { cwd: root, env: f.env, encoding: 'utf8', timeout: 10_000 });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /CommandError/);
    assert.match(readFileSync(f.summary, 'utf8'), /`measurement:simctl-timeout`: launch/);
    const report = spawnSync('python3', [reporter], { cwd: root, encoding: 'utf8', timeout: 10_000,
      env: { ...f.env, RUNNER_TEMP: f.dir, GITHUB_STEP_SUMMARY: join(f.dir, 'final'), RUNTIME_PHASE_OUTCOMES: '{"inspector":"failure"}' } });
    assert.equal(report.status, 0, report.stderr);
    assert.match(report.stdout, /observed simctl timeouts: `launch`/);
    assert.doesNotMatch(report.stdout, /private-device|private-bundle/);
  } finally { f.cleanup(); }
});

test('summary filters malformed, duplicate and successful phase measurements', () => {
  const f = fixture();
  try {
    writeFileSync(f.summary, '- `measurement:simctl-timeout`: launch\n- `measurement:simctl-timeout`: launch\n- `measurement:simctl-timeout`: launch private-device\n- `measurement:simctl-timeout`: unknown-operation\n');
    const run = (outcomes: string) => spawnSync('python3', [reporter], { cwd: root, encoding: 'utf8', timeout: 10_000,
      env: { ...f.env, RUNNER_TEMP: f.dir, GITHUB_STEP_SUMMARY: join(f.dir, 'final'), RUNTIME_PHASE_OUTCOMES: outcomes } });
    const failed = run('{"inspector":"failure"}');
    assert.equal(failed.status, 0, failed.stderr);
    assert.match(failed.stdout, /no infrastructure label recorded; observed simctl timeouts: `launch`/);
    assert.equal(failed.stdout.match(/`launch`/g)?.length, 1);
    assert.doesNotMatch(failed.stdout, /private-device|unknown-operation/);
    const successful = run('{"inspector":"success"}');
    assert.equal(successful.status, 0, successful.stderr);
    assert.doesNotMatch(successful.stdout, /simctl timeouts/);
  } finally { f.cleanup(); }
});

test('only simulator phases enable measurement', () => {
  const workflow = readFileSync(join(root, '.github/workflows/runtime-m4.yml'), 'utf8');
  for (const key of ['create', 'watch', 'lck', 'inspector', 'cleanup']) {
    const phase = workflow.split(`        id: ${key}\n`)[1]?.split('      - ')[0];
    assert.ok(phase);
    assert.match(phase, /export CKSIM_RECORD_TIMEOUT_OPERATIONS=1/);
  }
  const controls = workflow.split('        id: controls\n')[1]?.split('      - ')[0];
  assert.ok(controls);
  assert.doesNotMatch(controls, /CKSIM_RECORD_TIMEOUT_OPERATIONS/);
});
