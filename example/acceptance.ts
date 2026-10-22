import {
  endConversation,
  getConversations,
  joinConversation,
  reportConversation,
  reportIncomingConversation,
  setConversationHandler,
  setHeld,
  type ActionContext,
  type Conversation,
  type ConversationHandler,
  type IncomingCallPayload,
  type PushToken,
} from 'ios-voip-sdk';

import { journey } from './journey';

type Fields = Record<string, string | boolean | number | null>;
let traceQueue = Promise.resolve();
let automaticRun: Promise<void> | undefined;
let hookSnapshot: readonly Conversation[] | undefined;
let tokenHookSeen = false;

export function trace(event: string, fields: Fields = {}): Promise<void> {
  traceQueue = traceQueue.then(() =>
    journey().trace(event, JSON.stringify(fields)),
  );
  return traceQueue;
}

export function observeConversations(
  conversations: readonly Conversation[],
): void {
  hookSnapshot = conversations;
  const conversation = conversations[0];
  void trace('m1.hookConversations', {
    count: conversations.length,
    conversationID: conversation?.id ?? null,
    status: conversation?.status ?? null,
    pending: conversation?.pending?.kind ?? null,
    hasConnectedAt: conversation?.connectedAt !== undefined,
  });
}

export function observeToken(token: PushToken | null): void {
  tokenHookSeen = true;
  void trace('m1.hookToken', {
    available: token !== null,
    tokenType: token?.type ?? null,
  });
}

async function check(
  label: string,
  passed: boolean,
  conversationID?: string,
): Promise<void> {
  await trace('m1.assertion', {
    label,
    passed,
    conversationID: conversationID ?? null,
  });
  if (!passed) throw new Error('Example acceptance assertion failed: ' + label);
}

const sleep = (milliseconds: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

async function waitFor(
  predicate: (snapshot: readonly Conversation[]) => boolean,
  timeoutMS = 8_000,
): Promise<readonly Conversation[]> {
  const deadline = Date.now() + timeoutMS;
  while (Date.now() < deadline) {
    const snapshot = await getConversations();
    if (predicate(snapshot)) return snapshot;
    await sleep(25);
  }
  throw new Error('Example state observation deadline');
}

async function waitForHook(
  predicate: (snapshot: readonly Conversation[]) => boolean,
): Promise<void> {
  const deadline = Date.now() + 8_000;
  while (Date.now() < deadline) {
    if (hookSnapshot !== undefined && predicate(hookSnapshot)) return;
    await sleep(25);
  }
  throw new Error('Example hook observation deadline');
}

function payload(): IncomingCallPayload {
  return {
    eventId: 'sdk-example-event-' + journey().runID,
    serverCallId: 'sdk-example-server-' + journey().runID,
    caller: {
      id: 'sdk-example-caller',
      displayName: 'SDK example',
      phoneNumber: '+15555550142',
    },
    hasVideo: false,
  };
}

async function action(
  kind: string,
  conversation: Conversation,
  context: ActionContext,
  fields: Fields = {},
): Promise<void> {
  context.signal.addEventListener(
    'abort',
    () => {
      void trace('m1.cancelled', {
        conversationID: conversation.id,
        kind,
        reason: 'nativeCancellation',
      });
    },
    { once: true },
  );
  await trace('m1.handler', {
    conversationID: conversation.id,
    kind,
    deadline: context.deadline,
    origin: context.origin,
    ...fields,
  });
  if (context.signal.aborted) throw new Error('Example action cancelled');
}

/** Demonstration signaling only; production apps resolve after their transport accepts. */
export function exampleHandler(): ConversationHandler {
  return {
    join: (conversation, context) => action('join', conversation, context),
    start: (conversation, context) => action('start', conversation, context),
    end: (conversation, context) => action('end', conversation, context),
    hold: (conversation, context) =>
      action('hold', conversation, context, { held: context.held }),
    mute: (conversation, context) =>
      action('mute', conversation, context, { muted: context.muted }),
    tones: (conversation, context) => action('tones', conversation, context),
  };
}

async function attachHandler(): Promise<void> {
  await trace('m1.handlerAttached', { attached: true });
  setConversationHandler(exampleHandler());
}

async function endAndObserve(id: string): Promise<void> {
  await endConversation(id);
  await waitFor((snapshot) => snapshot.length === 0);
  await waitForHook((snapshot) => snapshot.length === 0);
  await check('ended-empty', true, id);
}

async function run(): Promise<void> {
  const mode = journey().m1Case;
  try {
    if (mode === 'journey') {
      await attachHandler();
      await journey().simulatePush(
        JSON.stringify({ incomingCall: payload() }),
        true,
        'primary',
      );
      const ringing = await waitFor(
        (snapshot) => snapshot.length === 1 && snapshot[0].status === 'ringing',
      );
      const id = ringing[0].id;
      await waitForHook(
        (snapshot) => snapshot.length === 1 && snapshot[0].status === 'ringing',
      );
      await check('push-ringing', true, id);
      await sleep(1_000);
      await check(
        'ring-survives',
        (await getConversations())[0]?.status === 'ringing',
        id,
      );
      const sameEvent = await reportIncomingConversation({
        ...payload(),
        serverCallId: 'sdk-example-alternate-server',
      });
      const sameServer = await reportIncomingConversation({
        ...payload(),
        eventId: 'sdk-example-alternate-event',
      });
      await check('dedup-event', sameEvent === id, id);
      await check('dedup-server', sameServer === id, id);
      await check(
        'dedup-single-conversation',
        (await getConversations()).length === 1,
        id,
      );
      await joinConversation(id);
      await waitFor(
        (snapshot) =>
          snapshot[0]?.status === 'connecting' &&
          snapshot[0].pending === undefined &&
          snapshot[0].connectedAt === undefined,
      );
      await check('joined', true, id);
      await reportConversation(id, { type: 'connected' });
      await waitFor((snapshot) => snapshot[0]?.connectedAt !== undefined);
      await waitForHook((snapshot) => snapshot[0]?.connectedAt !== undefined);
      await check('connected-report', true, id);
      await setHeld(id, true);
      await waitFor((snapshot) => snapshot[0]?.status === 'held');
      await waitForHook((snapshot) => snapshot[0]?.status === 'held');
      await check('held', true, id);
      await setHeld(id, false);
      await waitFor((snapshot) => snapshot[0]?.status === 'connected');
      await waitForHook((snapshot) => snapshot[0]?.status === 'connected');
      await check('resumed', true, id);
      await endAndObserve(id);
    } else if (mode === 'cold-launch' || mode === 'unhandled-expiry') {
      const cold = await journey().waitForColdStart();
      const initial = await getConversations();
      await check(
        'cold-snapshot-pending',
        initial.some(
          (conversation) =>
            conversation.id === cold.conversationID &&
            conversation.pending?.id === cold.actionID &&
            conversation.pending.kind === 'join',
        ),
        cold.conversationID,
      );
      await waitForHook((snapshot) =>
        snapshot.some(
          (conversation) =>
            conversation.id === cold.conversationID &&
            conversation.pending?.id === cold.actionID,
        ),
      );
      await check('cold-hook-pending', true, cold.conversationID);
      if (mode === 'cold-launch') {
        await attachHandler();
        await waitFor(
          (snapshot) =>
            snapshot[0]?.status === 'connecting' &&
            snapshot[0].pending === undefined &&
            snapshot[0].connectedAt === undefined,
        );
        await check('cold-redelivered', true, cold.conversationID);
        await reportConversation(cold.conversationID, { type: 'connected' });
        await endAndObserve(cold.conversationID);
      } else {
        const remaining = Date.parse(cold.deadline) - Date.now();
        await check(
          'platform-deadline-visible',
          Number.isFinite(remaining) && remaining > 0,
          cold.conversationID,
        );
        const final = await waitFor(
          (snapshot) => snapshot.length === 0,
          Math.max(0, remaining) + 8_000,
        );
        await waitForHook((snapshot) => snapshot.length === 0);
        await trace('m1.expiryObserved', {
          conversationID: cold.conversationID,
          count: final.length,
        });
        await check(
          'unhandled-expired-empty',
          final.length === 0,
          cold.conversationID,
        );
      }
    } else {
      throw new Error('Unknown M1 acceptance case');
    }
    await check('token-hook-observed', tokenHookSeen);
    await traceQueue;
    await journey().finish(true);
  } catch (error) {
    // No arbitrary error/payload/token values enter the native evidence stream.
    await traceQueue.catch(() => {});
    await journey().finish(false);
    throw error;
  }
}

export function runAcceptance(): Promise<void> {
  automaticRun ??= run();
  return automaticRun;
}
