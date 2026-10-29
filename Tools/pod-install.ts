import { spawn } from 'node:child_process';
import { appendFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const bounded = fileURLToPath(new URL('../scripts/ci/bounded', import.meta.url));
const downloadCommand = /Failed to download .*https:\/\/repo[.]reactnative[.]dev\/|\/usr\/bin\/curl .*https:\/\/repo[.]reactnative[.]dev\//;
const downloadFailure = /curl: \([0-9]+\)|Failed to download/;

type Attempt = { status: number; dependencyFailure: boolean };

async function install(args: readonly string[]): Promise<Attempt> {
  return await new Promise((resolve) => {
    const child = spawn(bounded, ['600', 'pod', 'install', ...args], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let interrupted: 130 | 143 | undefined;
    const onInterrupt = (): void => { interrupted ??= 130; child.kill('SIGINT'); };
    const onTerminate = (): void => { interrupted ??= 143; child.kill('SIGTERM'); };
    const cleanup = (): void => {
      process.off('SIGINT', onInterrupt);
      process.off('SIGTERM', onTerminate);
    };
    process.on('SIGINT', onInterrupt);
    process.on('SIGTERM', onTerminate);
    let tail = '';
    let commandSeen = false;
    let failureSeen = false;
    const receive = (chunk: Buffer, target: NodeJS.WriteStream): void => {
      target.write(chunk);
      tail = (tail + chunk.toString('utf8')).slice(-16_384);
      commandSeen ||= downloadCommand.test(tail);
      failureSeen ||= downloadFailure.test(tail);
    };
    child.stdout.on('data', (chunk: Buffer) => receive(chunk, process.stdout));
    child.stderr.on('data', (chunk: Buffer) => receive(chunk, process.stderr));
    child.once('error', (error) => {
      cleanup();
      console.error(error.message);
      resolve({ status: 1, dependencyFailure: false });
    });
    child.once('close', (code, signal) => {
      cleanup();
      resolve({ status: interrupted ?? code ?? (signal === 'SIGINT' ? 130 : signal ? 143 : 1),
        dependencyFailure: commandSeen && failureSeen });
    });
  });
}

async function main(): Promise<number> {
  for (let attempt = 1; attempt <= 2; attempt++) {
    const result = await install(process.argv.slice(2));
    if (result.status === 0 || result.status >= 128 || !result.dependencyFailure) return result.status;
    const message = attempt === 1
      ? '- `infra:dependency-download`: failed; scheduled one bounded re-attempt'
      : '- `infra:dependency-download`: re-attempt exhausted';
    console.error(message);
    if (process.env.GITHUB_STEP_SUMMARY) {
      try { await appendFile(process.env.GITHUB_STEP_SUMMARY, `${message}\n`); } catch { /* Diagnostics must not replace the failure. */ }
    }
    if (attempt === 2) return result.status;
  }
  return 1;
}

process.exitCode = await main();
