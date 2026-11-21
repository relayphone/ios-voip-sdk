import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { preparePackage, sdkTargets, sdkSourceDirectory } from '../../scripts/prepare-package.mts';

export const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

export function podspecFixture(t: { after: (cleanup: () => void) => void }) {
  const root = mkdtempSync(join(tmpdir(), 'voip-podspec-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'expo/ios'), { recursive: true });
  writeFileSync(join(root, 'VERSION'), '0.2.1\n');
  writeFileSync(join(root, 'expo/package.json'), JSON.stringify({
    name: '@relayphone/ios-voip-sdk', version: '0.2.1', description: 'Calls for iOS',
    homepage: 'https://github.com/relayphone/ios-voip-sdk', author: 'Relayphone', license: 'MIT',
  }));
  for (const target of sdkTargets) {
    mkdirSync(sdkSourceDirectory(root, target), { recursive: true });
    const file = target === 'VoIPPushDelivery' ? 'Example.h' : 'Example.swift';
    writeFileSync(join(sdkSourceDirectory(root, target), file), '// source fixture\n');
  }
  copyFileSync(join(packageRoot, 'ios/VoIPConversations.podspec'), join(root, 'expo/ios/VoIPConversations.podspec'));
  preparePackage(root);
  return root;
}
