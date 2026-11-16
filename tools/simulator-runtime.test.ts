import assert from 'node:assert/strict';
import test from 'node:test';
import { requireSimulatorRuntime, simulatorRuntime } from './simulator-runtime.ts';

const runtime = { identifier: simulatorRuntime, isAvailable: true, bundlePath: '/runtime/iOS.simruntime',
  version: '27.2', buildversion: '24C101' };
const inventory = (...runtimes: object[]) => JSON.stringify({ runtimes });

test('requires the pinned available runtime and checks its actual bundle path', () => {
  const checked: string[] = [];
  assert.deepEqual(requireSimulatorRuntime(inventory(runtime), path => { checked.push(path); return true; }), runtime);
  assert.deepEqual(checked, [runtime.bundlePath]);
});

test('rejects an older runtime instead of silently falling back', () => {
  assert.throws(() => requireSimulatorRuntime(inventory({ ...runtime,
    identifier: 'com.apple.CoreSimulator.SimRuntime.iOS-27-0' }), () => true), /unavailable/);
});

test('rejects an unavailable runtime even if its path exists', () => {
  assert.throws(() => requireSimulatorRuntime(inventory({ ...runtime, isAvailable: false }), () => true), /unavailable/);
});

test('rejects missing or unmounted runtime paths before boot', () => {
  assert.throws(() => requireSimulatorRuntime(inventory({ ...runtime, bundlePath: '' }), () => true), /path is missing/);
  assert.throws(() => requireSimulatorRuntime(inventory(runtime), () => false), /path is missing/);
});
