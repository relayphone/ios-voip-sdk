// Running the host's tools from the TypeScript tools.
import { spawnSync, type SpawnSyncOptions } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** The repository checkout that contains the tools. */
export const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export interface RunOptions {
  /** Seconds before the command is killed. */
  timeout?: number;
  environment?: NodeJS.ProcessEnv;
  directory?: string;
  /** Pass the command's output through instead of returning it. */
  inherit?: boolean;
}

/** Runs a command and returns its trimmed output, failing if it doesn't succeed. */
export function run(command: string, args: readonly string[], options: RunOptions = {}): string {
  const spawnOptions: SpawnSyncOptions = {
    cwd: options.directory ?? repository,
    env: options.environment ?? process.env,
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
    stdio: options.inherit ? ['ignore', 'inherit', 'inherit'] : ['ignore', 'pipe', 'pipe'],
    timeout: (options.timeout ?? 600) * 1000,
    killSignal: 'SIGKILL',
  };
  const result = spawnSync(command, args, spawnOptions);
  if (result.error) throw new Error(`${command} ${args.join(' ')}: ${result.error.message}`);
  if (result.status !== 0) {
    const detail = options.inherit ? '' : `\n${String(result.stdout)}${String(result.stderr)}`;
    throw new Error(`${command} ${args.join(' ')} exited with ${result.status ?? result.signal}${detail}`);
  }
  return options.inherit ? '' : String(result.stdout).trim();
}

/** The value after `--name` in the arguments, or undefined. */
export function option(args: readonly string[], name: string): string | undefined {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : undefined;
}

/** Whether a module is the program node was asked to run. */
export function isMain(url: string): boolean {
  return process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(url);
}

/** Runs a tool's main function, printing its failure and setting the exit status. */
export async function main(body: () => void | Promise<void>): Promise<void> {
  try {
    await body();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
