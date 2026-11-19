import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isMain, main, run } from './command.ts';
import { isList, isRecord, isString } from './json-fields.ts';

interface ResultSummary {
  failedTests: number;
  failures: readonly unknown[];
}
export type FailureClassification = 'product:tests' | 'infra:runner-hang' | 'infra:test-host-restart';
export interface SystemMemoryFailure { process: string; file: string }

/** Reads crash evidence from unrelated simulator services, not the SDK or its fixtures. */
export function systemMemoryFailures(directory: string) {
  const services = new Set(['containermanager', 'siriactionsd', 'donotdisturbd', 'SpringBoard', 'testmanagerd']);
  const failures: SystemMemoryFailure[] = [];
  const visit = (folder: string) => {
    for (const entry of readdirSync(folder, { withFileTypes: true })) {
      const file = join(folder, entry.name);
      if (entry.isDirectory()) { visit(file); continue; }
      if (!entry.isFile() || !entry.name.endsWith('.ips')) continue;
      try {
        const raw = readFileSync(file, 'utf8');
        const newline = raw.indexOf('\n');
        if (newline < 0) continue;
        const header: unknown = JSON.parse(raw.slice(0, newline));
        const body: unknown = JSON.parse(raw.slice(newline + 1));
        if (isRecord(header) && 'is_first_party' in header && header.is_first_party === 1
          && 'app_name' in header && isString(header.app_name) && services.has(header.app_name)
          && isRecord(body) && 'exception' in body && isRecord(body.exception)
          && 'signal' in body.exception && body.exception.signal === 'SIGBUS'
          && 'subtype' in body.exception && isString(body.exception.subtype)
          && body.exception.subtype.startsWith('KERN_MEMORY_ERROR at ')) {
          failures.push({ process: header.app_name, file: entry.name });
        }
      } catch { /* Partial or unsupported crash reports cannot establish infrastructure failure. */ }
    }
  };
  visit(directory);
  return failures;
}

function readSummary(text: string) {
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { return; }
  if (!isRecord(parsed) || !('failedTests' in parsed) || !Number.isSafeInteger(parsed.failedTests)) return;
  const failures = 'testFailures' in parsed ? parsed.testFailures : [];
  if (!isList(failures)) return;
  return { failedTests: Number(parsed.failedTests), failures } satisfies ResultSummary;
}

const assertionFailure = /Expectation failed:|recorded an issue|XCTAssert\w*.*failed|Assertion Failure/;

function hostRestartCandidate(summary: ResultSummary, log: string) {
  return summary.failedTests > 0 && summary.failures.length === summary.failedTests
    && summary.failures.every(failure => isRecord(failure) && 'failureText' in failure
      && failure.failureText === 'Test crashed with signal bus.')
    && log.includes('Restarting after unexpected exit, crash, or test timeout')
    && log.includes('unable to connect to "com.apple.instruments.deviceservice.lockdown"')
    && !assertionFailure.test(log);
}

function isConnectionHang(summary: ResultSummary, log: string) {
  return summary.failedTests === 0 && summary.failures.length === 0
    && log.includes('hung before establishing connection') && !assertionFailure.test(log);
}

/** A named test interrupted by a corroborated simulator-wide memory failure is not an assertion. */
export function classifySimulatorFailure(summary: string, log: string, systemFailures: readonly SystemMemoryFailure[] = []) {
  const parsed = readSummary(summary);
  if (!parsed || assertionFailure.test(log)) return 'product:tests' satisfies FailureClassification;
  if (isConnectionHang(parsed, log)) return 'infra:runner-hang' satisfies FailureClassification;
  if (hostRestartCandidate(parsed, log) && new Set(systemFailures.map(failure => failure.process)).size >= 2) {
    return 'infra:test-host-restart' satisfies FailureClassification;
  }
  return 'product:tests' satisfies FailureClassification;
}

/** The #266 retry rule: no failed tests, and a runner that hung before connecting. */
export function runnerHungBeforeConnecting(summary: string, log: string) {
  const parsed = readSummary(summary);
  return parsed !== undefined && isConnectionHang(parsed, log);
}

if (isMain(import.meta.url)) {
  await main(() => {
    const [summary, log, bundle] = process.argv.slice(2);
    if (!summary || !log || !bundle) throw new Error('Usage: simulator-test-result.ts <summary.json> <test.log> <tests.xcresult>');
    const result = readFileSync(summary, 'utf8');
    const output = readFileSync(log, 'utf8');
    const evidence: SystemMemoryFailure[] = [];
    const parsed = readSummary(result);
    if (parsed && hostRestartCandidate(parsed, output)) {
      const scratch = mkdtempSync(join(tmpdir(), 'simulator-test-diagnostics-'));
      try {
        run('xcrun', ['xcresulttool', 'export', 'diagnostics', '--path', bundle,
          '--output-path', join(scratch, 'diagnostics')], { timeout: 60 });
        evidence.push(...systemMemoryFailures(join(scratch, 'diagnostics')));
      } catch { /* Missing corroboration keeps the failure terminal. */ }
      finally { rmSync(scratch, { recursive: true, force: true }); }
    }
    const classification = classifySimulatorFailure(result, output, evidence);
    writeFileSync(`${summary}.classification.json`, JSON.stringify({ classification, evidence }));
    console.log(classification);
  });
}
