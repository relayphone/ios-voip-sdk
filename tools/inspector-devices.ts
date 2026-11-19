import { simulatorRuntime } from './simulator-runtime.ts';
import { isList, isRecord, isString } from './json-fields.ts';
import { run } from './command.ts';

export interface DeviceType { name: string; identifier: string; productFamily: string }
function isIPhone(value: unknown): value is DeviceType {
  return isRecord(value) && 'productFamily' in value && value.productFamily === 'iPhone'
    && 'name' in value && isString(value.name) && 'identifier' in value && isString(value.identifier);
}

const preferred = [
  'com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation',
  'com.apple.CoreSimulator.SimDeviceType.iPhone-16e',
  'com.apple.CoreSimulator.SimDeviceType.iPhone-17e',
  'com.apple.CoreSimulator.SimDeviceType.iPhone-13-mini',
];

/** Selects only from the installed iOS 27.2 runtime's supported devices, preferring compact models. */
export function selectIPhone(json: string) {
  const inventory: unknown = JSON.parse(json);
  if (!isRecord(inventory) || !('runtimes' in inventory) || !isList(inventory.runtimes)) {
    throw new Error('Invalid simulator runtime inventory');
  }
  const runtime = inventory.runtimes.find(item =>
    isRecord(item) && 'identifier' in item && item.identifier === simulatorRuntime);
  if (!isRecord(runtime) || !('isAvailable' in runtime) || runtime.isAvailable !== true) {
    throw new Error('iOS 27.2 runtime is unavailable');
  }
  const supported = 'supportedDeviceTypes' in runtime && isList(runtime.supportedDeviceTypes)
    ? runtime.supportedDeviceTypes : [];
  const phones = supported.filter(isIPhone);
  const device = preferred.map(id => phones.find(d => d.identifier === id)).find(d => d !== undefined) ?? phones[0];
  if (!device) throw new Error('iOS 27.2 runtime lists no supported iPhone');
  return device;
}

/** Queries the runtime itself; device profile internals are not part of this interface. */
export function simulatorDevice() {
  const json = run('xcrun', ['simctl', 'list', 'runtimes', '-j'], { timeout: 120 });
  const device = selectIPhone(json);
  console.log(`Selected runtime-supported device: ${device.name} (${device.identifier})`);
  return device;
}
