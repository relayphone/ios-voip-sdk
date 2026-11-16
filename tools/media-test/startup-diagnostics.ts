export type StartupBoundary = 'unavailable' | 'preparationCompletionUnobserved' | 'activationNeverDelivered'
  | 'activationEnqueueUnobserved' | 'activationDropped' | 'activationStreamTerminated'
  | 'activationNotConsumed' | 'engineOutcomeUnobserved' | 'engineNotRunning' | 'engineRunning';
export interface StartupDiagnostics {
  readonly boundary: StartupBoundary;
  readonly clockID?: string;
  readonly lastAudioActivatedAtMs?: number;
  readonly lastAudioDeactivatedAtMs?: number;
}
const object = (value: unknown): Record<string, unknown> | undefined =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
const time = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const stages = ['prepareEntered', 'roomConnectRequested', 'roomConnectCompleted', 'roomConnectFailed',
  'captureOptionsApplied', 'prepareCompleted', 'activationEntered', 'activationEnqueued', 'activationHandlerEntered',
  'engineAvailabilityObserved', 'tapInstalled', 'firstCallback'] as const;

/** Diagnostic interpretation only: this never qualifies media or changes a success gate. */
export function diagnoseNativeStartup(value: unknown): StartupDiagnostics {
  const startup = object(object(value)?.startup);
  if (!startup || typeof startup.clockID !== 'string' ||
      !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(startup.clockID) ||
      !Array.isArray(startup.observations) || startup.observations.length > 13) return { boundary: 'unavailable' };
  const events = new Map<string, Record<string, unknown>>();
  let prior = 0;
  for (const value of startup.observations) {
    const row = object(value), event = object(row?.event), keys = event ? Object.keys(event) : [];
    const name = keys[0];
    if (!row || !time(row.atMs) || row.atMs < prior || keys.length !== 1 ||
        !stages.some(stage => stage === name)) return { boundary: 'unavailable' };
    prior = row.atMs;
    const associated = object(event![name!]);
    if (!associated) return { boundary: 'unavailable' };
    const key = name === 'tapInstalled' || name === 'firstCallback' ? `${name}:${associated._0}` : name!;
    if (events.has(key)) return { boundary: 'unavailable' };
    events.set(key, associated);
  }
  const activated = startup.lastAudioActivatedAtMs, deactivated = startup.lastAudioDeactivatedAtMs;
  if (activated !== undefined && activated !== null && !time(activated) ||
      deactivated !== undefined && deactivated !== null && !time(deactivated)) return { boundary: 'unavailable' };
  const base = { clockID: startup.clockID,
    ...(time(activated) ? { lastAudioActivatedAtMs: activated } : {}),
    ...(time(deactivated) ? { lastAudioDeactivatedAtMs: deactivated } : {}) };
  const result = (boundary: StartupBoundary): StartupDiagnostics => ({ ...base, boundary });
  if (!events.has('prepareCompleted')) return result('preparationCompletionUnobserved');
  if (!events.has('activationEntered')) return result('activationNeverDelivered');
  const enqueue = events.get('activationEnqueued')?._0;
  if (enqueue === 'dropped') return result('activationDropped');
  if (enqueue === 'terminated') return result('activationStreamTerminated');
  if (enqueue !== 'enqueued') return result('activationEnqueueUnobserved');
  if (!events.has('activationHandlerEntered')) return result('activationNotConsumed');
  const engine = events.get('engineAvailabilityObserved')?._0;
  return result(engine === 'running' ? 'engineRunning' : engine === 'unavailable' ? 'engineNotRunning' : 'engineOutcomeUnobserved');
}
