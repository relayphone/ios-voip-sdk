import { spawn } from 'node:child_process';
import { closeSync, openSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { run } from './command.ts';

/** Builds the bundled Debug example and retains Xcode's diagnostics. */
export async function buildBundledExample(work: string, example: string, app: string): Promise<void> {
  const log = join(work, 'build.log');
  const output = openSync(log, 'w');
  try {
    const build = spawn('xcodebuild', ['-workspace', 'ios/VoIPExample.xcworkspace', '-scheme', 'VoIPExample',
      '-configuration', 'Debug', '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', join(work, 'build'),
      'CODE_SIGNING_ALLOWED=NO', 'COMPILER_INDEX_STORE_ENABLE=NO', 'build'],
    { cwd: example, stdio: ['ignore', output, output] });
    await new Promise<void>((resolve, reject) => {
      build.once('error', reject);
      build.once('close', (status, signal) => {
        if (status === 0) resolve();
        else reject(new Error(`xcodebuild exited with ${status ?? signal}`));
      });
    });
    if (statSync(join(app, 'main.jsbundle')).size === 0) throw new Error('Empty bundled JavaScript');
  } catch (error) {
    try { console.error(run('tail', ['-100', log], { timeout: 3 })); }
    catch { /* The full build log is retained. */ }
    throw error;
  } finally {
    closeSync(output);
  }
}
