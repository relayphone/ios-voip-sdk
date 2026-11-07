import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const directory = dirname(require.resolve('@relayphone/ios-voip-sdk/package.json'));
const compiled = join(directory, 'build-scripts/prepare-package.mjs');
const checkout = existsSync(join(dirname(directory), 'VERSION')) &&
  existsSync(join(dirname(directory), 'Sources/VoIPCore'));

function run(command: string, args: string[]): void {
  const result = spawnSync(command, args, { stdio: 'inherit', timeout: 120_000 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`SDK preparation failed (${result.status ?? result.signal})`);
}

if (checkout) {
  run('npm', ['run', 'build', '--prefix', directory]);
  run('npm', ['run', 'sync:sources', '--prefix', directory]);
} else {
  run(process.execPath, [compiled, '--sync']);
}
