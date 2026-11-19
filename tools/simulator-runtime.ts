import { existsSync } from 'node:fs';
import { isMain, main, run } from './command.ts';
import { isList, isRecord, isString } from './json-fields.ts';

/** Test execution runtime; independent of application deployment targets and runtime profiles. */
export const simulatorRuntime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-2';

interface InstalledRuntime {
  identifier: string;
  isAvailable: boolean;
  bundlePath: string;
  version: string;
  buildversion: string;
}

function isInstalledRuntime(value: unknown): value is InstalledRuntime {
  return isRecord(value)
    && 'identifier' in value && isString(value.identifier)
    && 'isAvailable' in value && (value.isAvailable === true || value.isAvailable === false)
    && 'bundlePath' in value && isString(value.bundlePath)
    && 'version' in value && isString(value.version)
    && 'buildversion' in value && isString(value.buildversion);
}

/** Rejects missing runtime mounts before a simulator is booted. */
export function requireSimulatorRuntime(json: string, pathExists: (path: string) => boolean = existsSync) {
  const inventory: unknown = JSON.parse(json);
  if (!isRecord(inventory) || !('runtimes' in inventory) || !isList(inventory.runtimes)) {
    throw new Error('Invalid simulator runtime inventory');
  }
  const runtime = inventory.runtimes.find(item =>
    isRecord(item) && 'identifier' in item && item.identifier === simulatorRuntime);
  if (!isRecord(runtime) || !('isAvailable' in runtime) || runtime.isAvailable !== true) {
    throw new Error('iOS 27.2 simulator runtime is unavailable');
  }
  if (!('bundlePath' in runtime) || !isString(runtime.bundlePath) || !runtime.bundlePath || !pathExists(runtime.bundlePath)) {
    throw new Error('iOS 27.2 simulator runtime bundle path is missing');
  }
  if (!isInstalledRuntime(runtime)) throw new Error('Invalid simulator runtime inventory');
  return runtime;
}

if (isMain(import.meta.url)) await main(() => {
  const inventory = run('xcrun', ['simctl', 'list', 'runtimes', '--json'], { timeout: 120 });
  console.log(JSON.stringify(requireSimulatorRuntime(inventory)));
});
