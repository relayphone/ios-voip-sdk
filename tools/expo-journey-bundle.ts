import { writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { isMain, main, repository, run } from './command.ts';

/** Embeds production JavaScript while keeping the native Debug simulator runtime. */
export function configureBundledExample(ios: string): void {
  // Expo's development startup requires a server-backed bundle origin.
  writeFileSync(join(ios, '.xcode.env.updates'),
    'unset SKIP_BUNDLING\nexport FORCE_BUNDLING=1\nexport EXTRA_PACKAGER_ARGS="--dev false"\nexport ENTRY_FILE="$PROJECT_DIR/../journeys/entry.ts"\n');
}

/** Only the integration build uses the fixture's explicit deadlines. */
export function configureJourneyDeadline(ios: string, execute: typeof run = run, media = false): void {
  const plist = join(ios, 'VoIPExample/Info.plist');
  execute('plutil', ['-replace', 'VoIPConversationsFulfillAnswerCallTimeout', '-integer', '27',
    plist]);
  if (media) {
    // The media fixture performs a cold LiveKit handshake during Answer preparation.
    execute('plutil', ['-replace', 'VoIPConversationsMediaPreparationTimeout', '-integer', '10', plist]);
  }
}

/** Add transaction metrics to the pinned LiveKit client in the media fixture build. */
export function configureMediaWebSocketTiming(ios: string): void {
  const directory = join(ios, 'Pods', 'LiveKitClient');
  const patch = join(repository, 'tools', 'media-test', 'livekit-websocket-timing.patch');
  const options = { directory, environment: { ...process.env, GIT_CEILING_DIRECTORIES: dirname(directory) } };
  try { run('git', ['apply', '--reverse', '--check', patch], options); }
  catch { run('git', ['apply', patch], options); }
}

if (isMain(import.meta.url)) await main(() => {
  const [ios, media, ...extra] = process.argv.slice(2);
  if (!ios || (media !== undefined && media !== '--media') || extra.length) {
    throw new Error('Usage: expo-journey-bundle.ts <example iOS directory> [--media]');
  }
  configureBundledExample(resolve(ios));
  configureJourneyDeadline(resolve(ios), run, media === '--media');
  if (media) configureMediaWebSocketTiming(resolve(ios));
});
