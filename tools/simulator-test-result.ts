import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isMain, main, run } from './command.ts';

interface ResultSummary {
  failedTests?: unknown;
  testFailures?: { failureText?: unknown }[];
}
export type FailureClassification = 'product:tests' | 'infra:runner-hang' | 'infra:test-host-restart';
export interface SystemMemoryFailure { process: string; file: string }

/** Reads crash evidence from unrelated simulator services, not the SDK or its fixtures. */
export function systemMemoryFailures(directory: string): SystemMemoryFailure[] {
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
        const header = JSON.parse(raw.slice(0, newline)) as { app_name?: unknown; is_first_party?: unknown };
        const body = JSON.parse(raw.slice(newline + 1)) as { exception?: { signal?: unknown; subtype?: unknown } };
        if (header.is_first_party === 1 && typeof header.app_name === 'string' && services.has(header.app_name)
          && body.exception?.signal === 'SIGBUS' && typeof body.exception.subtype === 'string'
          && body.exception.subtype.startsWith('KERN_MEMORY_ERROR at ')) {
          failures.push({ process: header.app_name, file: entry.name });
        }
      } catch { /* Partial or unsupported crash reports cannot establish infrastructure failure. */ }
    }
  };
  visit(directory);
  return failures;
}

function hostRestartCandidate(summary: ResultSummary, log: string): boolean {
  return Number.isSafeInteger(summary.failedTests) && Number(summary.failedTests) > 0
    && Array.isArray(summary.testFailures) && summary.testFailures.length === summary.failedTests
    && summary.testFailures.every(failure => failure?.failureText === 'Test crashed with signal bus.')
    && log.includes('Restarting after unexpected exit, crash, or test timeout')
    && log.includes('unable to connect to "com.apple.instruments.deviceservice.lockdown"')
    && !/Expectation failed:|recorded an issue|XCTAssert\w*.*failed|Assertion Failure/.test(log);
}

/** A named test interrupted by a corroborated simulator-wide memory failure is not an assertion. */
export function classifySimulatorFailure(summary: string, log: string, systemFailures: readonly SystemMemoryFailure[] = []): FailureClassification {
  let parsed: ResultSummary;
  try { parsed = JSON.parse(summary) as ResultSummary; } catch { return 'product:tests'; }
  if (!parsed || typeof parsed !== 'object') return 'product:tests';
  if (/Expectation failed:|recorded an issue|XCTAssert\w*.*failed|Assertion Failure/.test(log)) return 'product:tests';
  if ((!parsed.testFailures || Array.isArray(parsed.testFailures) && parsed.testFailures.length === 0)
    && runnerHungBeforeConnecting(summary, log)) return 'infra:runner-hang';
  if (hostRestartCandidate(parsed, log) && new Set(systemFailures.map(failure => failure.process)).size >= 2) {
    return 'infra:test-host-restart';
  }
  return 'product:tests';
}

/** The #266 retry rule: no failed tests, and a runner that hung before connecting. */
export function runnerHungBeforeConnecting(summary: string, log: string): boolean {
  const count: unknown = (JSON.parse(summary) as { failedTests?: unknown }).failedTests;
  return Number.isSafeInteger(count) && Number(count) === 0
    && log.includes('hung before establishing connection');
}

if (isMain(import.meta.url)) {
  await main(() => {
    const [summary, log, bundle] = process.argv.slice(2);
    if (!summary || !log || !bundle) throw new Error('Usage: simulator-test-result.ts <summary.json> <test.log> <tests.xcresult>');
    const result = readFileSync(summary, 'utf8');
    const output = readFileSync(log, 'utf8');
    const evidence: SystemMemoryFailure[] = [];
    if (hostRestartCandidate(JSON.parse(result) as ResultSummary, output)) {
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
