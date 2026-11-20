export type StartupBoundary = 'unavailable' | 'preparationCompletionUnobserved' | 'activationNeverDelivered'
  | 'activationEnqueueUnobserved' | 'activationDropped' | 'activationStreamTerminated'
  | 'activationNotConsumed' | 'engineOutcomeUnobserved' | 'engineNotRunning' | 'engineRunning';
interface PreparationObservation {
  readonly stage: typeof preparationStages[number];
  readonly atMs: number;
}
interface RoomConnectionObservation {
  readonly stage: typeof roomConnectionStages[number];
  readonly elapsedMs: number;
}
export interface StartupDiagnostics {
  readonly boundary: StartupBoundary;
  readonly clockID?: string;
  readonly lastAudioActivatedAtMs?: number;
  readonly lastAudioDeactivatedAtMs?: number;
  readonly preparation?: readonly PreparationObservation[];
  readonly roomConnectionSteps?: readonly RoomConnectionObservation[];
  readonly roomConnectionBeganAtMs?: number;
  readonly roomConnectionCancelledAtMs?: number;
}
const object = (value: unknown): Record<string, unknown> | undefined =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
const time = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const preparationStages = ['prepareEntered', 'roomConnectRequested', 'roomConnectCompleted', 'roomConnectFailed',
  'captureOptionsApplied'] as const;
const roomConnectionStages = ['ws_task_resumed', 'ws_dns_start', 'ws_dns_end', 'ws_tcp_start', 'ws_tcp_end',
  'ws_upgrade_request', 'ws_upgrade_response', 'ws_metrics_clock_sample_start', 'ws_metrics_received',
  'ws_native_open', 'ws_ipv4', 'ws_ipv6', 'ws_proxy',
  'ws_multiple_transactions', 'ws_open', 'join_recv', 'pc_created', 'offer_sent', 'answer_sent',
  'pc_connected', 'room_connected'] as const;
const stages = [...preparationStages, 'prepareCompleted', 'activationEntered', 'activationEnqueued', 'activationHandlerEntered',
  'engineAvailabilityObserved', 'tapInstalled', 'firstCallback'] as const;

/** Diagnostic interpretation only: this never qualifies media or changes a success gate. */
export function diagnoseNativeStartup(value: unknown): StartupDiagnostics {
  const payload = object(value), startup = object(payload?.startup);
  if (!startup || typeof startup.clockID !== 'string' ||
      !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(startup.clockID) ||
      !Array.isArray(startup.observations) || startup.observations.length > 13) return { boundary: 'unavailable' };
  const events = new Map<string, Record<string, unknown>>();
  const preparation: PreparationObservation[] = [];
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
    const stage = preparationStages.find(stage => stage === name);
    if (stage) preparation.push({ stage, atMs: row.atMs });
  }
  const activated = startup.lastAudioActivatedAtMs, deactivated = startup.lastAudioDeactivatedAtMs;
  if (activated !== undefined && activated !== null && !time(activated) ||
      deactivated !== undefined && deactivated !== null && !time(deactivated)) return { boundary: 'unavailable' };
  const began = payload?.roomConnectionBeganAtMs, cancelled = payload?.roomConnectionCancelledAtMs;
  const roomConnection = payload?.roomConnectionSteps;
  const roomConnectionSteps: RoomConnectionObservation[] | undefined =
    Array.isArray(roomConnection) && roomConnection.length <= 32 ? roomConnection.flatMap(value => {
      const row = object(value);
      const stage = roomConnectionStages.find(label => label === row?.stage);
      return stage && time(row?.elapsedMs) ? [{ stage, elapsedMs: row.elapsedMs }] : [];
    }) : undefined;
  const base = { clockID: startup.clockID,
    ...(time(activated) ? { lastAudioActivatedAtMs: activated } : {}),
    ...(time(deactivated) ? { lastAudioDeactivatedAtMs: deactivated } : {}),
    ...(time(began) ? { roomConnectionBeganAtMs: began } : {}),
    ...(time(cancelled) ? { roomConnectionCancelledAtMs: cancelled } : {}),
    ...(roomConnectionSteps === undefined ? {} : { roomConnectionSteps }) };
  const result = (boundary: StartupBoundary): StartupDiagnostics => ({ ...base, boundary });
  if (!events.has('prepareCompleted')) return {
    ...result('preparationCompletionUnobserved'), ...(preparation.length ? { preparation } : {}),
  };
  if (!events.has('activationEntered')) return result('activationNeverDelivered');
  const enqueue = events.get('activationEnqueued')?._0;
  if (enqueue === 'dropped') return result('activationDropped');
  if (enqueue === 'terminated') return result('activationStreamTerminated');
  if (enqueue !== 'enqueued') return result('activationEnqueueUnobserved');
  if (!events.has('activationHandlerEntered')) return result('activationNotConsumed');
  const engine = events.get('engineAvailabilityObserved')?._0;
  return result(engine === 'running' ? 'engineRunning' : engine === 'unavailable' ? 'engineNotRunning' : 'engineOutcomeUnobserved');
}
