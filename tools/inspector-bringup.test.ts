import assert from 'node:assert/strict';
import { test } from 'node:test';
import { smallestIPhone, type DeviceType } from './inspector-devices.ts';
import { boundedTail, captureTail, memoryMargin } from './inspector-resources.ts';

const device = (name: string, maxRuntimeVersion = 0xffffffff): DeviceType => ({
  name, identifier: name, bundlePath: '/fixture', minRuntimeVersion: 18 * 65536, maxRuntimeVersion,
});
test('selects the smallest compatible iPhone rather than a smaller obsolete model or iPad', () => {
  const small = device('iPhone Small');
  assert.equal(smallestIPhone([
    { device: device('iPhone Old', 26 * 65536), width: 100, height: 200 },
    { device: device('iPad'), width: 100, height: 200 },
    { device: device('iPhone Pro'), width: 1200, height: 2600 },
    { device: small, width: 750, height: 1334 },
  ]), small);
  assert.throws(() => smallestIPhone([]), /No iOS 27/);
});
test('resource summary retains worst memory pressure and minimum free pages across samples', () => {
  assert.equal(memoryMargin('Pages free: 123.\nSystem-wide memory free percentage: 20%\n'
    + 'Pages free: 456.\nSystem-wide memory free percentage: 70%'),
  'peak memory pressure: 80% used (memory_pressure -Q); minimum free pages: 123');
  assert.throws(() => memoryMargin('sampler failed'), /did not capture/);
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
