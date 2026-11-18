import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { test } from 'node:test';
import { performance } from 'node:perf_hooks';
import { confirmGroupsStopped, runTestProcess } from './test-process.ts';
import { nativeTestPlan, nativeTestSucceeded } from './run-native-tests.ts';

const banner = `console.log('SIMULATOR_TEST_PROCESS '+process.pid);`;
const passed = `console.log('✔ Test run with 1 test in 1 suite passed after 0.1 seconds.');`;
const run = (script: string, timeoutMS = 2000, extra = {}) => runTestProcess({
  command: process.execPath, args: ['-e', banner + script], timeoutMS, ...extra,
});

test('native success requires real exit, a nonempty test run and cleanup', async () => {
  const result = await run(passed);
  assert.equal(result.code, 0); assert.equal(result.clean, true); assert.equal(nativeTestSucceeded(result), true);
  assert.equal(nativeTestSucceeded({ ...result, code: 65 }), false);
  assert.equal(nativeTestSucceeded({ ...result, clean: false }), false);
  assert.equal(nativeTestSucceeded({ ...result, log: '' }), false);
  assert.equal(nativeTestSucceeded({ ...result, log: '✔ Test run with 0 tests in 0 suites passed after 0.0 seconds.' }), false);
  const failed = await run(passed + 'process.exit(7)');
  assert.equal(failed.code, 7); assert.equal(nativeTestSucceeded(failed), false);
});

test('a passed line followed by a hang remains a failed timeout', async () => {
  const result = await run(passed + `process.on('SIGALRM',()=>{});setInterval(()=>{},1000)`, 200);
  assert.equal(result.reason, 'timeout'); assert.equal(result.signal, 'SIGKILL');
  assert.equal(result.clean, true); assert.equal(nativeTestSucceeded(result), false);
  assert.ok(result.elapsedMS < 1500);
});

test('native control startup does not spend the execution budget', async (context) => {
  context.mock.timers.enable({ apis: ['setTimeout'] });
  const marker = 'NATIVE_LAUNCHER_CONTROL success';
  const pending = run(`console.log('${marker}');${passed}`, 20, {
    readiness: { line: marker, timeoutMS: 1000 },
  });
  context.mock.timers.tick(20);
  const result = await pending;
  assert.ok(result.log.includes(marker), 'Control must actually reach native execution');
  assert.ok(result.readyElapsedMS !== undefined);
  assert.equal(result.code, 0);
});

test('a launcher that never reaches its native control has a distinct bounded startup failure', async (context) => {
  context.mock.timers.enable({ apis: ['setTimeout'] });
  const pending = run('setInterval(() => {}, 1000)', 20, {
    readiness: { line: 'NATIVE_LAUNCHER_CONTROL hang', timeoutMS: 100 },
  });
  context.mock.timers.tick(100);
  const result = await pending;
  assert.equal(result.reason, 'startupTimeout');
  assert.equal(result.readyElapsedMS, undefined);
  assert.equal(nativeTestSucceeded(result), false);
});

test('the exact stdout marker starts the stalled control execution timer', async () => {
  const marker = 'NATIVE_LAUNCHER_CONTROL hang';
  const result = await run(`
    console.error('${marker}');
    console.log('${marker} unexpected');
    process.stdout.write('NATIVE_LAUNCHER_');
    setImmediate(() => console.log('CONTROL hang'));
    setInterval(() => {}, 1000);
  `, 100, { readiness: { line: marker, timeoutMS: 2000 } });
  assert.equal(result.reason, 'timeout');
  assert.equal(result.signal, 'SIGKILL');
  assert.equal(result.clean, true);
  assert.ok(result.readyElapsedMS !== undefined);
});

test('near matches and stderr do not satisfy native control readiness', async () => {
  const marker = 'NATIVE_LAUNCHER_CONTROL success';
  const result = await run(`console.log('${marker} unexpected');console.error('${marker}');`, 100, {
    readiness: { line: marker, timeoutMS: 2000 },
  });
  assert.equal(result.code, 0);
  assert.equal(result.readyElapsedMS, undefined);
});

test('exited parents cannot leave inherited output and workers alive', async () => {
  const started = performance.now();
  const result = await run(`const {spawn}=require('node:child_process');
    spawn(process.execPath,['-e',"process.on('SIGTERM',()=>{});setTimeout(()=>{},10000)"],{stdio:['ignore',1,2]});
    ${passed}process.exit(0);`, 1000);
  assert.equal(result.reason, 'outputHeldOpen'); assert.equal(result.code, 0);
  assert.equal(result.clean, true); assert.equal(nativeTestSucceeded(result), false);
  assert.ok(performance.now() - started < 2000);
});

test('output limits and launch failures stay failures; logs redact fixture secrets', async () => {
  const result = await run(`console.log('private-fixture');${passed}`, 2000, { secrets: ['private-fixture'] });
  assert.ok(!result.log.includes('private-fixture')); assert.ok(result.log.includes('<REDACTED>'));
  const overflow = await run(`process.stdout.write('x'.repeat(100000));setInterval(()=>{},1000)`, 2000, { outputLimit: 4096 });
  assert.equal(overflow.reason, 'outputLimit'); assert.equal(overflow.clean, true);
  assert.ok(Buffer.byteLength(overflow.log) <= 4096);
  const missing = await runTestProcess({ command: '/missing-native-test-command', args: [], timeoutMS: 100 });
  assert.equal(missing.reason, 'launchError'); assert.equal(nativeTestSucceeded(missing), false);
});

test('launch plans preserve fixture environment, select suites and reject unsupported targets', () => {
  const target = { TestBundlePath: '__TESTROOT__/Tests.xctest',
    TestHostPath: '__PLATFORMS__/Simulator/Agents/xctest',
    TestingEnvironmentVariables: { DYLD_LIBRARY_PATH: '__TESTROOT__/Libraries' },
    EnvironmentVariables: { VIDEO_CALIBRATION_FIXTURE: '/private/fixture.json' } };
  const spec = { TestConfigurations: [{ TestTargets: [target] }] };
  const plan = nativeTestPlan(spec, '/build', '/Xcode', 'selected-device', '/test-host', 'Tests.Video');
  assert.deepEqual(plan.args, ['simctl','spawn','selected-device','/test-host','/Xcode/Simulator/Agents/xctest','-XCTest','Tests.Video','/build/Tests.xctest']);
  assert.equal(plan.env.SIMCTL_CHILD_DYLD_LIBRARY_PATH, '/build/Libraries');
  assert.equal(plan.env.SIMCTL_CHILD_VIDEO_CALIBRATION_FIXTURE, '/private/fixture.json');
  for (const patch of [{ IsAppHostedTestBundle: true }, { IsUITestBundle: true },
    { OnlyTestIdentifiers: ['Tests.Video'] }, { SkipTestIdentifiers: ['Tests.Video'] },
    { TestBundlePath: '__UNKNOWN__/Tests.xctest' }]) {
    assert.throws(() => nativeTestPlan({ TestConfigurations: [{ TestTargets: [{ ...target, ...patch }] }] }, '/build','/Xcode','sim','/host'));
  }
  assert.throws(() => nativeTestPlan({ TestConfigurations: [{ TestTargets: [target, target] }] }, '/build','/Xcode','sim','/host'));
});

test('interruption kills the owned test instead of accepting prior success output', async () => {
  const timer = setTimeout(() => process.kill(process.pid, 'SIGTERM'), 150);
  try {
    const result = await run(passed + 'setInterval(()=>{},1000)');
    assert.equal(result.reason, 'interrupted'); assert.equal(result.clean, true);
    assert.equal(nativeTestSucceeded(result), false);
  } finally { clearTimeout(timer); }
});

test('split UTF-8 output preserves the native test verdict', async () => {
  const result = await run(`process.stdout.write(Buffer.from([0xe2]));
    setTimeout(()=>{process.stdout.write(Buffer.from([0x9c,0x94]));
    console.log(' Test run with 1 test in 1 suite passed after 0.1 seconds.');},20);`);
  assert.equal(result.code, 0); assert.equal(nativeTestSucceeded(result), true);
});

test('signal errors after group removal cannot escape cleanup callbacks', async () => {
  const original = process.kill;
  process.kill = ((pid, signal) => {
    const result = original(pid, signal);
    if (pid < 0 && signal === 'SIGKILL') throw Object.assign(new Error('Removed group'), {code:'EPERM'});
    return result;
  }) as typeof process.kill;
  try {
    const result = await run('setInterval(()=>{},1000)', 150);
    assert.equal(result.reason, 'timeout'); assert.equal(result.clean, true);
    assert.deepEqual(result.cleanupErrors, ['EPERM']);
  } finally { process.kill = original; }
});

test('a live unkillable group is unclean and cannot keep the supervisor waiting', async () => {
  const original = process.kill;
  let pid: number | undefined;
  process.kill = ((group, signal) => {
    if (group < 0 && signal === 'SIGKILL') throw Object.assign(new Error('Unkillable group'), {code:'EPERM'});
    return original(group, signal);
  }) as typeof process.kill;
  try {
    const result = await run('setInterval(()=>{},1000)', 150);
    pid = result.nativePID;
    assert.equal(result.reason, 'timeout'); assert.equal(result.clean, false);
    assert.ok(result.cleanupErrors.includes('liveProcessGroup'));
    assert.equal(nativeTestSucceeded(result), false); assert.ok(result.elapsedMS < 2000);
  } finally {
    process.kill = original;
    if (pid) { try { original(-pid, 'SIGKILL'); } catch { /* Already reaped. */ } }
  }
});

test('reaped process groups do not depend on a fresh process table scan', async () => {
  const child = spawn(process.execPath, ['-e', ''], { detached: true, stdio: 'ignore' });
  const [code] = await once(child, 'close');
  assert.equal(code, 0);
  assert.ok(child.pid);
  const errors = new Set<string>();
  const inspect = async () => { throw Object.assign(new Error('Inspection timed out'), { signal: 'SIGKILL' }); };
  assert.equal(await confirmGroupsStopped([child.pid], errors, inspect), true);
  assert.deepEqual([...errors], []);
});

test('an inspection failure still rejects an extant group', async () => {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { detached: true, stdio: 'ignore' });
  const closed = once(child, 'close');
  await once(child, 'spawn');
  assert.ok(child.pid);
  const errors = new Set<string>();
  const inspect = async () => { throw Object.assign(new Error('Inspection timed out'), { signal: 'SIGKILL' }); };
  try {
    assert.equal(await confirmGroupsStopped([child.pid], errors, inspect), false);
    assert.deepEqual([...errors], ['processInspection:SIGKILL']);
  } finally {
    process.kill(-child.pid, 'SIGKILL');
    await closed;
  }
});

test('an inspection failure can be resolved by observing the group disappear', async () => {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { detached: true, stdio: 'ignore' });
  const closed = once(child, 'close');
  await once(child, 'spawn');
  const pid = child.pid;
  assert.ok(pid);
  const errors = new Set<string>();
  const inspect = async () => {
    process.kill(-pid, 'SIGKILL');
    await closed;
    throw Object.assign(new Error('Inspection timed out'), { signal: 'SIGKILL' });
  };
  try {
    assert.equal(await confirmGroupsStopped([pid], errors, inspect), true);
    assert.deepEqual([...errors], []);
  } finally {
    if (child.exitCode === null && child.signalCode === null) process.kill(-pid, 'SIGKILL');
    await closed;
  }
});

test('stderr cannot split a native JSON receipt in stdout', async () => {
  const result = await run(`process.stdout.write('VIDEO_CALIBRATION {"value":');
    setTimeout(()=>{process.stderr.write('decoder diagnostic\\n');
      setTimeout(()=>{console.log('1}');${passed}},20);},20);`);
  const line = result.log.split('\n').find(line=>line.startsWith('VIDEO_CALIBRATION '))!;
  assert.deepEqual(JSON.parse(line.slice('VIDEO_CALIBRATION '.length)), {value:1});
  assert.ok(result.stderr.includes('decoder diagnostic'));
});

test('Swift Testing may report its completed result on stderr', async () => {
  const result = await run(passed.replace('console.log','console.error'));
  assert.equal(result.code, 0); assert.equal(nativeTestSucceeded(result), true);
  assert.ok(!result.log.includes('Test run with'));
});
