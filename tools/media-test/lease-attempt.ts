type AttemptOutcome =
  | { outcome: 'success' | 'timeout' | 'cancelled' | 'parse failure' }
  | { outcome: 'exit'; code: number | string; stderr: string };

export type LeaseAttempt = AttemptOutcome & {
  stage: 'initial proof' | 'proof refresh' | 'launchd PID';
  attempt: number;
  startedAt: string;
  durationMS: number;
};

export interface AttemptDiagnostics {
  now: () => number;
  elapsed: () => number;
  redact: (value: string) => string;
  report: (attempt: LeaseAttempt) => void;
}

export async function measureLeaseAttempt<T>(
  stage: LeaseAttempt['stage'], attempt: number, signal: AbortSignal, diagnostics: AttemptDiagnostics,
  read: () => Promise<string>, parse: (stdout: string) => T,
): Promise<{ value: T } | { failure: LeaseAttempt; error: unknown }> {
  const { now, elapsed, redact, report } = diagnostics;
  const startedAt = new Date(now()).toISOString();
  const start = elapsed();
  function record(outcome: AttemptOutcome): LeaseAttempt {
    const entry = { stage, attempt, startedAt, durationMS: Math.round(elapsed() - start), ...outcome };
    report(entry);
    return entry;
  }

  let stdout: string;
  try {
    stdout = await read();
    signal.throwIfAborted();
  } catch (error) {
    const { killed, code, signal: exitSignal, stderr } = (error ?? {}) as {
      killed?: boolean; code?: number | string | null; signal?: string | null; stderr?: unknown;
    };
    const firstLine = typeof stderr === 'string'
      ? redact(stderr).split(/\r?\n/, 1)[0]!.replace(/[\x00-\x1f\x7f]/g, ' ').trim().slice(0, 240) : '';
    const failure = record(signal.aborted ? { outcome: 'cancelled' }
      : killed && code == null ? { outcome: 'timeout' }
      : { outcome: 'exit', code: code ?? exitSignal ?? 'unknown', stderr: firstLine });
    return { failure, error };
  }

  let value: T;
  try { value = parse(stdout); }
  catch (error) { return { failure: record({ outcome: 'parse failure' }), error }; }
  record({ outcome: 'success' });
  return { value };
}

export function summarizeLeaseAttempts(stage: LeaseAttempt['stage'], attempts: LeaseAttempt[]): string {
  const outcomes = attempts.map(entry => {
    if (entry.outcome === 'timeout') return 'timeout ' + (entry.durationMS / 1_000).toFixed(1) + 's';
    if (entry.outcome === 'exit') return 'exit ' + entry.code + (entry.stderr ? ' ' + JSON.stringify(entry.stderr) : '');
    return entry.outcome;
  });
  return stage + ': ' + attempts.length + (attempts.length === 1 ? ' attempt' : ' attempts')
    + (outcomes.length ? ' (' + outcomes.join(', ') + ')' : '');
}
