import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const wrapper = join(root, 'Tools/pod-install.ts');

type Outcome = 'network' | 'rn' | 'other' | 'foreign' | 'interrupted' | 'ok';

function runPod(first: Outcome, second: Outcome = 'ok') {
  const directory = mkdtempSync(join(tmpdir(), 'pod-retry-'));
  try {
    const pod = join(directory, 'pod');
    writeFileSync(pod, `#!/usr/bin/env node
const fs = require('node:fs');
let count = fs.existsSync(process.env.POD_CALLS) ? Number(fs.readFileSync(process.env.POD_CALLS)) : 0;
fs.writeFileSync(process.env.POD_CALLS, String(++count));
fs.appendFileSync(process.env.POD_ARGS, process.argv.slice(2).join(' ') + '\\n');
const behavior = count === 1 ? process.env.POD_FIRST : process.env.POD_SECOND;
if (behavior === 'network' || behavior === 'interrupted') {
  console.log('[!] /usr/bin/curl https://repo.reactnative.dev/maven2/file.tgz\\ncurl: (16) HTTP2 error');
  if (behavior === 'interrupted') process.kill(process.pid, 'SIGTERM');
  else process.exit(7);
} else if (behavior === 'rn') {
  console.log('[ReactNativeDependencies] Failed to download tarball from https://repo.reactnative.dev/maven2/file.tgz'); process.exit(3);
} else if (behavior === 'foreign') {
  console.log('[ReactNativeDependencies] Using https://repo.reactnative.dev/maven2/file.tgz\\n[!] /usr/bin/curl https://example.org/file.tgz\\ncurl: (56) connection reset'); process.exit(8);
} else if (behavior === 'other') { console.log('[!] Invalid Podfile'); process.exit(9); }
else console.log('installed');
`, { mode: 0o755 });
    const summaryPath = join(directory, 'summary');
    const result = spawnSync(process.execPath, [wrapper, '--no-repo-update'], {
      cwd: directory, encoding: 'utf8', timeout: 30_000,
      env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, POD_CALLS: join(directory, 'calls'),
        POD_ARGS: join(directory, 'args'), POD_FIRST: first, POD_SECOND: second, GITHUB_STEP_SUMMARY: summaryPath },
    });
    let summary = '';
    try { summary = readFileSync(summaryPath, 'utf8'); } catch { /* No classification was written. */ }
    return { result, calls: readFileSync(join(directory, 'calls'), 'utf8'),
      args: readFileSync(join(directory, 'args'), 'utf8'), summary };
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

test('identified download failures retry once with the same arguments', () => {
  for (const kind of ['network', 'rn'] as const) {
    const { result, calls, args, summary } = runPod(kind);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(calls, '2');
    assert.deepEqual(args.trim().split('\n'), ['install --no-repo-update', 'install --no-repo-update']);
    assert.match(summary, /infra:dependency-download.*scheduled one bounded re-attempt/);
  }
});

test('exhausted retries retain the second status', () => {
  const { result, calls, summary } = runPod('network', 'rn');
  assert.equal(result.status, 3);
  assert.equal(calls, '2');
  assert.match(summary, /re-attempt exhausted/);
});

test('unrelated errors and interruptions are not retried', () => {
  for (const [kind, code] of [['other', 9], ['foreign', 8], ['interrupted', 143]] as const) {
    const { result, calls, summary } = runPod(kind);
    assert.equal(result.status, code, result.stderr);
    assert.equal(calls, '1');
    assert.equal(summary, '');
  }
});

test('workflow wires cached installs and pinned versions', () => {
  const workflow = readFileSync(join(root, '.github/workflows/sdk-m0.yml'), 'utf8');
  const blocks = workflow.split(/(?=^  [\w-]+:\s*$)/m).filter(block => block.includes('Tools/pod-install.ts'));
  assert.equal(blocks.length, 3);
  for (const block of blocks) assert.match(block, /uses: \.\/\.github\/actions\/cache-native-dependencies/);
  const action = readFileSync(join(root, '.github/actions/cache-native-dependencies/action.yml'), 'utf8');
  for (const value of ['Tools/native-dependency-versions.ts', 'steps.versions.outputs.rn',
    'steps.versions.outputs.hermes', "hashFiles('package-lock.json')", '~/Library/Caches/ReactNative', '~/Library/Caches/CocoaPods']) {
    assert.ok(action.includes(value), value);
  }
});


test('cache versions are read from the locked native dependencies', () => {
  const directory = mkdtempSync(join(tmpdir(), 'native-versions-'));
  try {
    const output = join(directory, 'output');
    writeFileSync(join(directory, 'package-lock.json'), JSON.stringify({ packages: {
      'node_modules/react-native': { version: '0.88.0' },
      'node_modules/hermes-compiler': { version: '260318099.0.4' },
    } }));
    const result = spawnSync(process.execPath, [join(root, 'Tools/native-dependency-versions.ts')], {
      cwd: directory, encoding: 'utf8', env: { ...process.env, GITHUB_OUTPUT: output },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(output, 'utf8'), 'rn=0.88.0\nhermes=260318099.0.4\n');
    writeFileSync(join(directory, 'package-lock.json'), JSON.stringify({ packages: {} }));
    const invalid = spawnSync(process.execPath, [join(root, 'Tools/native-dependency-versions.ts')], {
      cwd: directory, encoding: 'utf8', env: { ...process.env, GITHUB_OUTPUT: output },
    });
    assert.notEqual(invalid.status, 0);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});


test('parent cancellation stops the bounded pod process', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'pod-cancel-'));
  const pidPath = join(directory, 'pid');
  let child: ReturnType<typeof spawn> | undefined;
  try {
    writeFileSync(join(directory, 'pod'), `#!/usr/bin/env node
require('node:fs').writeFileSync(process.env.POD_PID, String(process.pid));
setInterval(() => {}, 1000);
`, { mode: 0o755 });
    child = spawn(process.execPath, [wrapper], {
      cwd: directory, stdio: 'ignore', env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, POD_PID: pidPath },
    });
    const completed = once(child, 'close');
    for (let i = 0; i < 100 && !existsSync(pidPath); i++) await delay(50);
    assert.ok(existsSync(pidPath), 'pod should start');
    const pid = Number(readFileSync(pidPath, 'utf8'));
    child.kill('SIGTERM');
    const [code] = await completed;
    assert.equal(code, 143);
    assert.throws(() => process.kill(pid, 0));
  } finally {
    if (child && child.exitCode === null && child.signalCode === null) {
      const completed = once(child, 'close');
      child.kill('SIGTERM');
      await completed;
    }
    rmSync(directory, { recursive: true, force: true });
  }
});
