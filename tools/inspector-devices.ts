import { run } from './command.ts';

export interface DeviceType { name: string; identifier: string; productFamily: string }
const preferred = [
  'com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation',
  'com.apple.CoreSimulator.SimDeviceType.iPhone-16e',
  'com.apple.CoreSimulator.SimDeviceType.iPhone-17e',
  'com.apple.CoreSimulator.SimDeviceType.iPhone-13-mini',
];

/** Selects only from the installed iOS 27 runtime's supported devices, preferring compact models. */
export function selectIPhone(json: string): DeviceType {
  const inventory = JSON.parse(json) as { runtimes: {
    identifier: string; isAvailable: boolean; supportedDeviceTypes?: DeviceType[];
  }[] };
  const runtime = inventory.runtimes.find(r => r.identifier === 'com.apple.CoreSimulator.SimRuntime.iOS-27-0');
  if (!runtime?.isAvailable) throw new Error('iOS 27 runtime is unavailable');
  const phones = (runtime.supportedDeviceTypes ?? []).filter(d => d.productFamily === 'iPhone'
    && typeof d.name === 'string' && typeof d.identifier === 'string');
  const device = preferred.map(id => phones.find(d => d.identifier === id)).find(d => d !== undefined) ?? phones[0];
  if (!device) throw new Error('iOS 27 runtime lists no supported iPhone');
  return device;
}

/** Queries the runtime itself; device profile internals are not part of this interface. */
export function simulatorDevice(): DeviceType {
  const json = run('xcrun', ['simctl', 'list', 'runtimes', '-j'], { timeout: 120 });
  const device = selectIPhone(json);
  console.log(`Selected runtime-supported device: ${device.name} (${device.identifier})`);
  return device;
}
