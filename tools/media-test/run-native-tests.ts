import { execFile } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { runTestProcess, type TestProcessReadiness, type TestProcessResult } from './test-process.ts';

const execute = promisify(execFile);
interface TestTarget {
  TestBundlePath: string;
  TestHostPath: string;
  TestingEnvironmentVariables?: Record<string, string>;
  EnvironmentVariables?: Record<string, string>;
  IsAppHostedTestBundle?: boolean;
  IsUITestBundle?: boolean;
  OnlyTestIdentifiers?: string[];
  SkipTestIdentifiers?: string[];
}
interface Specification { TestConfigurations: { TestTargets: TestTarget[] }[] }

/** Resolves only standalone native bundles; unsupported hosting or filters fail closed. */
export function nativeTestPlan(specification: Specification, root: string, platforms: string, simulator: string, host: string, only?: string) {
  const configurations = specification.TestConfigurations;
  if (configurations.length !== 1 || configurations[0]!.TestTargets.length !== 1) throw Error('Expected one standalone native test target');
  const target = configurations[0]!.TestTargets[0]!;
  if (target.IsAppHostedTestBundle || target.IsUITestBundle || target.OnlyTestIdentifiers?.length || target.SkipTestIdentifiers?.length) {
    throw Error('Unsupported native test hosting or embedded selection');
  }
  const expand = (value: string) => {
    const result = value.replaceAll('__TESTROOT__', root).replaceAll('__PLATFORMS__', platforms);
    if (/__[A-Z_]+__/.test(result)) throw Error('Unresolved native test path');
    return result;
  };
  const executable = expand(target.TestHostPath), bundle = expand(target.TestBundlePath);
  if (!isAbsolute(executable) || !isAbsolute(bundle) || !bundle.endsWith('.xctest') || !executable.endsWith('/xctest')) throw Error('Expected an absolute xctest host and bundle');
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries({ ...target.TestingEnvironmentVariables, ...target.EnvironmentVariables })) {
    if (typeof value !== 'string') throw Error('Invalid native test environment');
    env[`SIMCTL_CHILD_${key}`] = expand(value);
  }
  const args = ['simctl', 'spawn', simulator, host, executable, ...(only ? ['-XCTest', only] : []), bundle];
  return { args, env };
}

/** Requires native exit, a nonempty Swift Testing result and confirmed process cleanup. */
export function nativeTestSucceeded(result: TestProcessResult): boolean {
  const summary = /^✔ Test run with [1-9]\d* tests? in [^\n]+ passed after /m;
  return result.reason === 'exit' && result.code === 0 && result.signal === null && result.clean &&
    (summary.test(result.log) || summary.test(result.stderr));
}

/** Runs prebuilt tests directly, avoiding xcodebuild's separate result-collection teardown. */
export async function runNativeTests(options: {
  specification: string; simulator: string; host: string; directory: string;
  timeoutMS: number; only?: string; secrets?: string[]; readiness?: TestProcessReadiness;
}) {
  const specification = resolve(options.specification), directory = resolve(options.directory);
  const [{ stdout: data }, { stdout: developer }] = await Promise.all([
    execute('/usr/bin/plutil', ['-convert', 'json', '-o', '-', specification], { timeout: 5000 }),
    execute('/usr/bin/xcode-select', ['-p'], { timeout: 5000 }),
  ]);
  const plan = nativeTestPlan(JSON.parse(data) as Specification, dirname(specification), join(developer.trim(), 'Platforms'), options.simulator, resolve(options.host), options.only);
  if (!existsSync(options.host)) throw Error('Missing simulator test host');
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const result = await runTestProcess({ command: '/usr/bin/xcrun', args: plan.args,
    env: { ...process.env, ...plan.env }, timeoutMS: options.timeoutMS, secrets: options.secrets,
    readiness: options.readiness });
  const { log, stderr, ...receipt } = result;
  const success = (!options.readiness || result.readyElapsedMS !== undefined) && nativeTestSucceeded(result);
  writeFileSync(join(directory, 'tests.log'), log);
  writeFileSync(join(directory, 'stderr.log'), stderr);
  writeFileSync(join(directory, 'launcher.json'), JSON.stringify({ ...receipt, success }, null, 2) + '\n');
  return { ...result, success };
}

if (import.meta.main) {
  const [seconds, directory, simulator, specification, host, only] = process.argv.slice(2);
  if (!seconds || !directory || !simulator || !specification || !host) throw Error('Usage: run-native-tests.ts <seconds> <directory> <simulator> <specification> <host> [module.suite]');
  try {
    const result = await runNativeTests({ timeoutMS: Number(seconds) * 1000, directory, simulator, specification, host, only });
    process.stdout.write(result.log); process.stderr.write(result.stderr);
    process.exitCode = result.success ? 0 : result.reason === 'timeout' ? 142 : 1;
  } catch { console.error('Native test launch failed'); process.exitCode = 1; }
}
