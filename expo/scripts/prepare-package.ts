import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** SDK targets compiled by the package's optional CocoaPods subspecs. */
export const sdkTargets = [
  'VoIPCore', 'VoIPAudio', 'VoIPLiveCommunicationKit', 'VoIPPushKit', 'VoIPPushDelivery',
  'VoIPNotifications', 'VoIPLiveActivity', 'VoIPFocus', 'VoIPSimulator',
  'CKSimProtocol', 'Engine', 'Interposition',
] as const;

/** Reject a package version that differs from the tag's SDK version. */
export function checkVersion(repository: string): void {
  const version = readFileSync(join(repository, 'VERSION'), 'utf8').trim();
  const packageValue: unknown = JSON.parse(readFileSync(join(repository, 'expo/package.json'), 'utf8'));
  if (!packageValue || typeof packageValue !== 'object' || !('version' in packageValue) ||
      packageValue.version !== version) {
    throw new Error(`The Expo package version must equal VERSION (${version})`);
  }
}

/** Copy source files, without build outputs or the standalone simulator loader. */
export function preparePackage(repository: string): void {
  checkVersion(repository);
  for (const target of sdkTargets) {
    if (!existsSync(join(repository, 'Sources', target))) throw new Error(`Missing SDK target: ${target}`);
  }
  const vendor = join(repository, 'expo/ios/Vendor');
  rmSync(vendor, { recursive: true, force: true });
  mkdirSync(vendor, { recursive: true });
  for (const target of sdkTargets) {
    cpSync(join(repository, 'Sources', target), join(vendor, target), {
      recursive: true,
      filter: path => !path.endsWith('CKLoader.m') &&
        (extname(path) === '' || ['.swift', '.m', '.h'].includes(extname(path))),
    });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  preparePackage(resolve(dirname(fileURLToPath(import.meta.url)), '../..'));
}
