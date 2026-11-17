import { writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isMain, main, run } from './command.ts';

/** Embeds production JavaScript while keeping the native Debug simulator runtime. */
export function configureBundledExample(ios: string): void {
  // Expo's development startup requires a server-backed bundle origin.
  writeFileSync(join(ios, '.xcode.env.updates'),
    'unset SKIP_BUNDLING\nexport FORCE_BUNDLING=1\nexport EXTRA_PACKAGER_ARGS="--dev false"\nexport ENTRY_FILE="$PROJECT_DIR/../journeys/entry.ts"\n');
}

/** Only the integration build uses the fixture's explicit connection deadline. */
export function configureJourneyDeadline(ios: string, execute: typeof run = run): void {
  execute('plutil', ['-replace', 'VoIPConversationsFulfillAnswerCallTimeout', '-integer', '27',
    join(ios, 'VoIPExample/Info.plist')]);
}

if (isMain(import.meta.url)) await main(() => {
  const [ios] = process.argv.slice(2);
  if (!ios) throw new Error('Usage: expo-journey-bundle.ts <example iOS directory>');
  configureBundledExample(resolve(ios));
  configureJourneyDeadline(resolve(ios));
});
