import { fileURLToPath } from 'node:url';
import { checkVendor, checkVersion } from '../expo/scripts/prepare-package.mts';
import { isMain, main } from './command.ts';

if (isMain(import.meta.url)) {
  await main(() => {
    const repository = fileURLToPath(new URL('..', import.meta.url));
    checkVersion(repository);
    checkVendor(repository);
    console.log('The Expo package version and existing Vendor sources match the SDK.');
  });
}
