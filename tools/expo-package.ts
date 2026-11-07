import { fileURLToPath } from 'node:url';
import { checkVersion } from '../expo/scripts/prepare-package.ts';
import { isMain, main } from './command.ts';

if (isMain(import.meta.url)) {
  await main(() => {
    checkVersion(fileURLToPath(new URL('..', import.meta.url)));
    console.log('The Expo package version equals VERSION.');
  });
}
