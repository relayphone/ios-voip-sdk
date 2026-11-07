import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { selectIPhone } from './inspector-devices.ts';
import { boundedTail, captureTail, memoryMargin, startResourceSampler } from './inspector-resources.ts';

const fixture = (name: string) => readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), 'utf8');
test('selects a preferred iPhone from the recorded runtime supported-device list', () => {
  assert.equal(selectIPhone(fixture('inspector-runtime')).identifier,
    'com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation');
});
test('falls back to the first supported iPhone when no preferred model exists', () => {
  assert.equal(selectIPhone(fixture('inspector-runtime-fallback')).identifier,
    'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro');
});
test('rejects an unavailable runtime or a runtime with no supported iPhones', () => {
  assert.throws(() => selectIPhone('{"runtimes":[]}'), /unavailable/);
  assert.throws(() => selectIPhone(JSON.stringify({runtimes: [{
    identifier: 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', isAvailable: true, supportedDeviceTypes: [],
  }]})), /no supported iPhone/);
});
test('resource summary retains worst memory pressure and minimum free pages across samples', () => {
  assert.equal(memoryMargin('Pages free: 123.\nSystem-wide memory free percentage: 20%\n'
    + 'Pages free: 456.\nSystem-wide memory free percentage: 70%'),
  'peak memory pressure: 80% used (memory_pressure -Q); minimum free pages: 123');
  assert.match(memoryMargin('sampler failed'), /^warning:resource-sampler/);
});
test('diagnostic tail is byte bounded, retaining the newest evidence', () => {
  assert.equal(boundedTail('abcdef', 3).toString(), 'def');
  assert.equal(boundedTail('é'.repeat(1000), 100).length, 100);
});

test('diagnostic capture streams large output into a bounded tail and retains failure stderr', async () => {
  const tail = await captureTail(process.execPath, ['-e', "process.stdout.write('x'.repeat(1_000_000) + 'end')"], 128);
  assert.equal(tail.length, 128);
  assert.equal(tail.subarray(-3).toString(), 'end');
  const failed = await captureTail(process.execPath, ['-e', "process.stderr.write('failure details'); process.exitCode = 1"], 128);
  assert.equal(failed.toString(), 'failure details');
});

test('sampler runs throughout the step, survives an error and stops on cancellation', () => {
  let calls = 0;
  let tick = () => {};
  let cancelled = false;
  const warnings: string[] = [];
  const stop = startResourceSampler(() => {
    calls++;
    if (calls === 2) throw new Error('sample unavailable');
  }, message => warnings.push(message), (callback, interval) => {
    assert.equal(interval, 15_000);
    tick = callback;
    return () => { cancelled = true; };
  });
  assert.equal(calls, 1);
  tick();
  tick();
  tick();
  assert.equal(calls, 4);
  assert.match(warnings[0]!, /sample unavailable/);
  stop();
  tick();
  assert.equal(cancelled, true);
  assert.equal(calls, 4);
});

test('resource summary includes coverage and warns about intermittent command failures', () => {
  const summary = memoryMargin('2026-11-07T13:00:00.000Z\nPages free: 123.\n'
    + 'System-wide memory free percentage: 20%\n2026-11-07T13:00:15.000Z\ntop: unavailable\n');
  assert.match(summary, /2 samples \(2026-11-07T13:00:00.000Z to 2026-11-07T13:00:15.000Z\)/);
  assert.match(summary, /warning:resource-sampler command failures/);
});
