import {
  getConversations,
  reportConversation,
  setConversationHandler,
  setMuted,
  type ActionContext,
  type Conversation,
  type ConversationHandler,
} from 'ios-voip-sdk';
import { journey } from './journey';

type Fields = Record<string, string | number | boolean | null>;
let queued = Promise.resolve();
let run: Promise<void> | undefined;
let releaseMute: (() => void) | undefined;
let appMute: Promise<void> | undefined;
let hook: readonly Conversation[] = [];

export function systemTrace(event: string, fields: Fields = {}): Promise<void> {
  queued = queued.then(() => journey().trace(event, JSON.stringify(fields)));
  return queued;
}

export function observeSystem(conversations: readonly Conversation[]): void {
  hook = conversations;
  for (const call of conversations.length ? conversations : [undefined]) {
    void systemTrace('system.hook', {
      count: conversations.length,
      conversationID: call?.id ?? null,
      status: call?.status ?? null,
      pending: call?.pending?.kind ?? null,
      hasConnectedAt: call?.connectedAt !== undefined,
      muted: call?.isMuted ?? false,
    });
  }
}

async function handle(
  kind: string,
  call: Conversation,
  context: ActionContext,
  fields: Fields = {},
): Promise<void> {
  await systemTrace('system.handler', {
    kind,
    conversationID: call.id,
    origin: context.origin,
    deadline: context.deadline,
    ...fields,
  });
  if (kind === 'mute' && context.origin === 'app') {
    // External control releases this only after the same-value system echo has
    // actually settled, so the A3 regression does not depend on a timer race.
    await new Promise<void>((resolve) => {
      releaseMute = resolve;
    });
  }
  if (context.signal.aborted)
    throw new Error('System fixture action cancelled');
}

const handler: ConversationHandler = {
  join: (call, context) => handle('join', call, context),
  start: () => {
    throw new Error('Unexpected outgoing action');
  },
  end: (call, context) => handle('end', call, context),
  hold: (call, context) =>
    handle('hold', call, context, { held: context.held }),
  mute: (call, context) =>
    handle('mute', call, context, { muted: context.muted }),
  tones: (call, context) =>
    handle('tones', call, context, { digits: context.digits }),
};

async function attach(): Promise<void> {
  await systemTrace('system.handlerAttached', { attached: true });
  setConversationHandler(handler);
}

async function execute(): Promise<void> {
  try {
    if (journey().systemCase !== 'push-launch') await attach();
    await systemTrace('system.ready', {
      attached: journey().systemCase !== 'push-launch',
    });
    while (true) {
      const command = await journey().nextSystemCommand();
      const id = command.conversationID;
      switch (command.operation) {
        case 'attach-handler':
          await attach();
          break;
        case 'backend-connected':
          if (!id) throw new Error('Missing backend conversation');
          await reportConversation(id, { type: 'connected' });
          await systemTrace('system.backendConnected', {
            id: command.id,
            conversationID: id,
          });
          break;
        case 'app-mute':
          if (!id || appMute) throw new Error('Invalid app mute barrier');
          await systemTrace('system.appMuteRequested', { conversationID: id });
          appMute = setMuted(id, false);
          break;
        case 'release-mute':
          if (!releaseMute || !appMute) throw new Error('No pending app mute');
          releaseMute();
          await appMute;
          await systemTrace('system.appMuteCompleted');
          break;
        case 'finish':
          if ((await getConversations()).length || hook.length)
            throw new Error('Final state/hook not empty');
          await systemTrace('system.commandCompleted', {
            id: command.id,
            operation: command.operation,
          });
          await journey().finish(true);
          return;
        default:
          throw new Error('Unknown system fixture command');
      }
      await systemTrace('system.commandCompleted', {
        id: command.id,
        operation: command.operation,
      });
    }
  } catch (error) {
    await queued;
    await journey().finish(false);
    throw error;
  }
}

export function runSystemAcceptance(): Promise<void> {
  run ??= execute();
  return run;
}
