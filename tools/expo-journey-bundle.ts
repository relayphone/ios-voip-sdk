import { writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isMain, main } from './command.ts';

/** Embeds production JavaScript while keeping the native Debug simulator runtime. */
export function configureBundledExample(ios: string): void {
  // Expo's development startup requires a server-backed bundle origin.
  writeFileSync(join(ios, '.xcode.env.updates'),
    'unset SKIP_BUNDLING\nexport FORCE_BUNDLING=1\nexport EXTRA_PACKAGER_ARGS="--dev false"\n');
}

if (isMain(import.meta.url)) await main(() => {
  const [ios] = process.argv.slice(2);
  if (!ios) throw new Error('Usage: expo-journey-bundle.ts <example iOS directory>');
  configureBundledExample(resolve(ios));
});
