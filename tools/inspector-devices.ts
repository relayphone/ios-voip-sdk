import { join } from 'node:path';
import { run } from './command.ts';

export interface DeviceType {
  name: string;
  identifier: string;
  bundlePath: string;
  minRuntimeVersion: number;
  maxRuntimeVersion: number;
}
export interface Screen { device: DeviceType; width: number; height: number }

/** The smallest available iPhone screen; runtime bounds exclude obsolete device types. */
export function smallestIPhone(screens: readonly Screen[]): DeviceType {
  const sorted = screens.filter(s => s.device.name.startsWith('iPhone')
    && s.device.minRuntimeVersion <= 27 * 65536 && s.device.maxRuntimeVersion >= 27 * 65536
    && Number.isFinite(s.width) && s.width > 0 && Number.isFinite(s.height) && s.height > 0)
    .toSorted((a, b) => a.width * a.height - b.width * b.height || a.device.name.localeCompare(b.device.name));
  if (!sorted[0]) throw new Error('No iOS 27-compatible iPhone screen found');
  return sorted[0].device;
}

/** Queries the image instead of assuming which iPhone models its runtime supports. */
export function displayDevice(): DeviceType {
  const output = run('xcrun', ['simctl', 'list', 'devicetypes', '--json'], { timeout: 120 });
  console.log(`Available simulator device types:\n${output}`);
  const types = (JSON.parse(output) as { devicetypes: DeviceType[] }).devicetypes;
  const runtimes = run('xcrun', ['simctl', 'list', 'runtimes', '--json'], { timeout: 120 });
  console.log(`Available simulator runtimes:
${runtimes}`);
  const runtime = (JSON.parse(runtimes) as { runtimes: {
    identifier: string; isAvailable: boolean; supportedDeviceTypes?: { identifier: string }[];
  }[] }).runtimes.find(r => r.identifier === 'com.apple.CoreSimulator.SimRuntime.iOS-27-0');
  if (!runtime?.isAvailable) throw new Error('iOS 27 runtime is unavailable');
  const supported = runtime.supportedDeviceTypes?.map(d => d.identifier);
  const screens = types.filter(d => (!supported || supported.includes(d.identifier)) && d.name.startsWith('iPhone')
    && d.minRuntimeVersion <= 27 * 65536 && d.maxRuntimeVersion >= 27 * 65536).map(device => {
    const profile = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-',
      join(device.bundlePath, 'Contents/Resources/profile.plist')])) as { mainScreenWidth: number; mainScreenHeight: number };
    return { device, width: profile.mainScreenWidth, height: profile.mainScreenHeight };
  });
  console.log(`Compatible iPhone screens: ${JSON.stringify(screens)}`);
  return smallestIPhone(screens);
}
