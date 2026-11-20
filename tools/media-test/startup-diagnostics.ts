import { isList, isNumber, isRecord, isString } from '../json-fields.ts';

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
interface StartupDetails {
  clockID?: string;
  lastAudioActivatedAtMs?: number;
  lastAudioDeactivatedAtMs?: number;
  preparation?: readonly PreparationObservation[];
  roomConnectionSteps?: readonly RoomConnectionObservation[];
  roomConnectionBeganAtMs?: number;
  roomConnectionCancelledAtMs?: number;
}
export interface StartupDiagnostics extends Readonly<StartupDetails> {
  readonly boundary: StartupBoundary;
}
const time = (value: unknown): value is number => isNumber(value) && Number.isFinite(value) && value >= 0;
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
export function diagnoseNativeStartup(value: unknown) {
  const unavailable: StartupDiagnostics = { boundary: 'unavailable' };
  if (!isRecord(value) || !('startup' in value) || !isRecord(value.startup)) return unavailable;
  const startup = new Map<string, unknown>(Object.entries(value.startup));
  const clockID = startup.get('clockID');
  const observations = startup.get('observations');
  if (!isString(clockID) || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(clockID) ||
      !isList(observations) || observations.length > 13) return unavailable;
  const events = new Map<string, unknown>();
  const preparation: PreparationObservation[] = [];
  let prior = 0;
  for (const row of observations) {
    if (!isRecord(row) || !('atMs' in row) || !time(row.atMs) || row.atMs < prior ||
        !('event' in row) || !isRecord(row.event)) return unavailable;
    const entries: [string, unknown][] = Object.entries(row.event);
    const [entry] = entries;
    if (entries.length !== 1 || !entry) return unavailable;
    const [name, associated] = entry;
    if (!stages.some(stage => stage === name) || !isRecord(associated)) return unavailable;
    const label = '_0' in associated ? associated._0 : undefined;
    const key = name === 'tapInstalled' || name === 'firstCallback' ? `${name}:${label}` : name;
    if (events.has(key)) return unavailable;
    events.set(key, label);
    prior = row.atMs;
    const stage = preparationStages.find(stage => stage === name);
    if (stage) preparation.push({ stage, atMs: row.atMs });
  }
  const activated = startup.get('lastAudioActivatedAtMs'), deactivated = startup.get('lastAudioDeactivatedAtMs');
  if (activated !== undefined && activated !== null && !time(activated) ||
      deactivated !== undefined && deactivated !== null && !time(deactivated)) return unavailable;
  const payload = new Map<string, unknown>(Object.entries(value));
  const began = payload.get('roomConnectionBeganAtMs'), cancelled = payload.get('roomConnectionCancelledAtMs');
  const roomConnection = payload.get('roomConnectionSteps');
  const details: StartupDetails = { clockID };
  if (time(activated)) details.lastAudioActivatedAtMs = activated;
  if (time(deactivated)) details.lastAudioDeactivatedAtMs = deactivated;
  if (time(began)) details.roomConnectionBeganAtMs = began;
  if (time(cancelled)) details.roomConnectionCancelledAtMs = cancelled;
  if (isList(roomConnection) && roomConnection.length <= 32) {
    details.roomConnectionSteps = roomConnection.flatMap(row => {
      if (!isRecord(row) || !('stage' in row) || !('elapsedMs' in row) || !time(row.elapsedMs)) return [];
      const stage = roomConnectionStages.find(label => label === row.stage);
      return stage ? [{ stage, elapsedMs: row.elapsedMs }] : [];
    });
  }
  const result = (boundary: StartupBoundary) => {
    const diagnostics: StartupDiagnostics = { ...details, boundary };
    return diagnostics;
  };
  if (!events.has('prepareCompleted')) {
    if (preparation.length) details.preparation = preparation;
    return result('preparationCompletionUnobserved');
  }
  if (!events.has('activationEntered')) return result('activationNeverDelivered');
  const enqueue = events.get('activationEnqueued');
  if (enqueue === 'dropped') return result('activationDropped');
  if (enqueue === 'terminated') return result('activationStreamTerminated');
  if (enqueue !== 'enqueued') return result('activationEnqueueUnobserved');
  if (!events.has('activationHandlerEntered')) return result('activationNotConsumed');
  const engine = events.get('engineAvailabilityObserved');
  return result(engine === 'running' ? 'engineRunning' : engine === 'unavailable' ? 'engineNotRunning' : 'engineOutcomeUnobserved');
}
