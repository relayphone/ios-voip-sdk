import type { Conversation, ConversationId, ConversationsApi } from '@relayphone/ios-voip-sdk';

export type LateHandlerScenario = 'before-deadline' | 'after-deadline' | 'preview-placement';
export interface LateHandlerConfiguration {
  schemaVersion: 1;
  runID: string;
  scenario: LateHandlerScenario;
  handlerAttachDelayMS: number;
  connectDeadlineMS: 27000;
}
export interface JourneyClock { nowMS(): number; sleepMS(duration: number): Promise<void> }
export const journeyClock: JourneyClock = {
  nowMS: () => performance.now(), sleepMS: ms => new Promise(resolve => setTimeout(resolve, ms)),
};
export interface FixtureTransport {
  starts: number;
  packetsSent: number;
  packetsReceived: number;
  start(id: ConversationId): Promise<void>;
}
/** No network or packet production: this fixture counts application transport starts. */
export class CountingTransport implements FixtureTransport {
  starts = 0;
  packetsSent = 0;
  packetsReceived = 0;
  async start(_id: ConversationId): Promise<void> { this.starts++; }
}
export interface LateHandlerResults {
  schemaVersion: 1;
  configuration: LateHandlerConfiguration;
  stage: 'waiting' | 'observed' | 'attached' | 'complete' | 'failed';
  observedAtMS?: number;
  attachedAtMS?: number;
  snapshots: Conversation['status'][];
  handlerInvocations: number;
  starts: number;
  packetsSent: number;
  packetsReceived: number;
  joinError?: string;
  failure?: string;
}
export function lateHandlerConfiguration(value: unknown): LateHandlerConfiguration {
  if (!value || typeof value !== 'object') throw new Error('Missing late-handler configuration');
  const config = value as Partial<LateHandlerConfiguration>;
  if (config.schemaVersion !== 1 || typeof config.runID !== 'string' || !/^[a-zA-Z0-9-]{1,64}$/.test(config.runID)
    || !['before-deadline', 'after-deadline', 'preview-placement'].includes(String(config.scenario))
    || !Number.isSafeInteger(config.handlerAttachDelayMS) || config.handlerAttachDelayMS! < 0
    || config.handlerAttachDelayMS! > 60000 || config.connectDeadlineMS !== 27000) {
    throw new Error('Invalid late-handler configuration');
  }
  return config as LateHandlerConfiguration;
}
export type LateHandlerApi = Pick<ConversationsApi, 'getConversations' | 'setConversationHandler'
  | 'joinConversation' | 'reportConversation'>;

/** Attaches through the ordinary API; native acknowledgement remains the readiness oracle. */
export async function driveLateHandler(configuration: LateHandlerConfiguration, api: LateHandlerApi,
  save: (result: LateHandlerResults) => void, clock = journeyClock, media: FixtureTransport = new CountingTransport(),
): Promise<void> {
  const config = lateHandlerConfiguration(configuration);
  const id = `${config.runID}-call` as ConversationId;
  const result: LateHandlerResults = { schemaVersion: 1, configuration: config, stage: 'waiting',
    snapshots: [], handlerInvocations: 0, starts: 0, packetsSent: 0, packetsReceived: 0 };
  const publish = (stage: LateHandlerResults['stage']) => {
    Object.assign(result, { stage, starts: media.starts, packetsSent: media.packetsSent, packetsReceived: media.packetsReceived });
    save(result);
  };
  const current = async () => (await api.getConversations()).find(call => call.id === id);
  async function until(read: () => Promise<boolean>, deadline = clock.nowMS() + 120000): Promise<void> {
    while (!await read()) {
      if (clock.nowMS() >= deadline) throw new Error('Late-handler observation timed out');
      await clock.sleepMS(100);
    }
  }
  publish('waiting');
  try {
    const preview = config.scenario === 'preview-placement';
    await until(async () => (await current())?.status === (preview ? 'previewing' : 'connecting'));
    result.observedAtMS = clock.nowMS();
    result.snapshots.push(preview ? 'previewing' : 'connecting');
    // Keep the rejection handled while the attachment clock waits past the placement deadline.
    const joining = preview ? api.joinConversation(id).then(() => 'unexpected-success', error =>
      typeof error === 'object' && error !== null && 'code' in error ? String(error.code) : String(error)) : undefined;
    publish('observed');
    const attachDue = result.observedAtMS + config.handlerAttachDelayMS;
    while (clock.nowMS() < attachDue) await clock.sleepMS(attachDue - clock.nowMS());
    if (config.scenario === 'after-deadline') {
      // A due timer still needs native executor time. Observe failure before late attachment;
      // the host independently requires its actual reason and journal ordering.
      await until(async () => !await current(), result.observedAtMS + 120000);
    }
    api.setConversationHandler({
      start() { throw new Error('Unexpected start handler'); },
      join() { result.handlerInvocations++; },
    });
    result.attachedAtMS = clock.nowMS();
    publish('attached');
    const call = await current();
    if (config.scenario === 'before-deadline') {
      if (call?.status !== 'connecting') throw new Error('Call expired before early attachment');
      await media.start(id);
      await api.reportConversation(id, { type: 'connected' });
      await until(async () => (await current())?.status === 'connected');
      result.snapshots.push('connected');
    } else if (preview) {
      result.joinError = await joining;
      if (result.joinError !== 'deadline_exceeded' || call?.status !== 'previewing'
        || result.handlerInvocations !== 0) throw new Error('Expired preview Join was reused');
      result.snapshots.push('previewing');
    } else if (call) {
      throw new Error(`Late attachment retained call in ${call.status}`);
    }
    publish('complete');
  } catch (error) {
    result.failure = String(error); publish('failed'); throw error;
  } finally { api.setConversationHandler(null); }
}
