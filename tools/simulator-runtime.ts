import { existsSync } from 'node:fs';
import { isMain, main, run } from './command.ts';

/** Test execution runtime; independent of application deployment targets and runtime profiles. */
export const simulatorRuntime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-2';

interface InstalledRuntime {
  identifier: string;
  isAvailable: boolean;
  bundlePath: string;
  version: string;
  buildversion: string;
}

/** Rejects missing runtime mounts before a simulator is booted. */
export function requireSimulatorRuntime(json: string, pathExists: (path: string) => boolean = existsSync): InstalledRuntime {
  const inventory = JSON.parse(json) as { runtimes: InstalledRuntime[] };
  const runtime = inventory.runtimes.find(item => item.identifier === simulatorRuntime);
  if (!runtime?.isAvailable) throw new Error('iOS 27.2 simulator runtime is unavailable');
  if (!runtime.bundlePath || !pathExists(runtime.bundlePath)) {
    throw new Error('iOS 27.2 simulator runtime bundle path is missing');
  }
  return runtime;
}

if (isMain(import.meta.url)) await main(() => {
  const inventory = run('xcrun', ['simctl', 'list', 'runtimes', '--json'], { timeout: 120 });
  console.log(JSON.stringify(requireSimulatorRuntime(inventory)));
});
