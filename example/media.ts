import {
  endConversation,
  getConversations,
  joinConversation,
  reportConversation,
  setConversationHandler,
  setHeld,
  type ActionContext,
  type Conversation,
  type ConversationHandler,
  type IncomingCallPayload,
} from 'ios-voip-sdk';

import { journey, type MediaSnapshot } from './journey';
import { callerFixture } from './callerFixture';

type Fields = Record<string, string | boolean | number | null>;
let traceQueue = Promise.resolve();
let automaticRun: Promise<void> | undefined;
let publicAudioEvents = 0;

function trace(event: string, fields: Fields): Promise<void> {
  traceQueue = traceQueue.then(() =>
    journey().trace(event, JSON.stringify(fields)),
  );
  return traceQueue;
}

/** Queue fixed hook metadata with this fixture's other evidence writes. */
export function observeMediaEvent(name: string, conversationID?: string): void {
  if (journey().m2Case === '') return;
  if (
    [
      'audioActivated',
      'audioDeactivated',
      'audioActivationMissing',
      'audioActivationFailed',
    ].includes(name)
  )
    publicAudioEvents += 1;
  // Keep a failed queue rejected for the final result, while handling this
  // fire-and-forget hook promise immediately.
  void trace('m2.hookEvent', {
    name,
    ...(conversationID === undefined ? {} : { conversationID }),
  }).catch(() => {});
}

function checkpoint(label: string, conversationID: string): Promise<void> {
  return trace('m2.assertion', { label, passed: true, conversationID });
}

const sleep = (milliseconds: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

async function waitForConversations(
  predicate: (snapshot: readonly Conversation[]) => boolean,
  timeoutMS = 8_000,
): Promise<readonly Conversation[]> {
  const deadline = Date.now() + timeoutMS;
  while (Date.now() < deadline) {
    const snapshot = await getConversations();
    if (predicate(snapshot)) return snapshot;
    await sleep(25);
  }
  throw new Error('Example media conversation observation deadline');
}

async function mediaSnapshot(label: string): Promise<MediaSnapshot> {
  // The example native method serializes only its whitelisted primitive fields.
  const snapshot: MediaSnapshot = JSON.parse(
    await journey().mediaSnapshot(label),
  );
  return snapshot;
}

async function waitForMedia(
  label: string,
  predicate: (snapshot: MediaSnapshot) => boolean,
  identity?: MediaSnapshot,
  timeoutMS = 8_000,
): Promise<MediaSnapshot> {
  const sameEngine = (sample: MediaSnapshot) =>
    !identity ||
    (sample.moduleID === identity.moduleID &&
      sample.deviceID === identity.deviceID);
  const deadline = Date.now() + timeoutMS;
  while (Date.now() < deadline) {
    const snapshot = await mediaSnapshot('poll');
    if (!sameEngine(snapshot)) {
      throw new Error('Example media engine identity changed');
    }
    if (predicate(snapshot)) {
      const recorded = await mediaSnapshot(label);
      if (!sameEngine(recorded)) {
        throw new Error('Example media engine identity changed');
      }
      return recorded;
    }
    await sleep(25);
  }
  throw new Error('Example media engine observation deadline');
}

function handler(
  prepareJoin: (signal: AbortSignal) => Promise<void>,
): ConversationHandler {
  const accept = async (
    kind: string,
    conversation: Conversation,
    context: ActionContext,
  ) => {
    await trace('m2.handler', {
      kind,
      conversationID: conversation.id,
      origin: context.origin,
    });
    if (context.signal.aborted)
      throw new Error('Example media action cancelled');
    // Native manual audio gating has completed; category/mode wait for acceptance.
    // Request capture while its real join action is still pending, so the
    // demand sample proves that capture cannot start before LCK activation.
    if (kind === 'join') await prepareJoin(context.signal);
    if (context.signal.aborted)
      throw new Error('Example media action cancelled');
  };
  return {
    join: (conversation, context) => accept('join', conversation, context),
    start: (conversation, context) => accept('start', conversation, context),
    end: (conversation, context) => accept('end', conversation, context),
    hold: (conversation, context) => accept('hold', conversation, context),
  };
}

function payload(): IncomingCallPayload {
  return {
    eventId: 'sdk-media-event-' + journey().runID,
    serverCallId: 'sdk-media-server-' + journey().runID,
    caller: callerFixture(),
    hasVideo: false,
  };
}

async function run(): Promise<void> {
  const mode = journey().m2Case;
  const stale = mode === 'stale-audio';
  let releaseStream: (() => number) | undefined;
  let conversationID: string | undefined;
  let stopRecording: (() => Promise<void>) | undefined;
  let closing = false;
  let success = false;
  try {
    if (mode !== 'livekit' && !stale)
      throw new Error('Unknown M2 acceptance case');
    // The none variant must never evaluate optional native media modules.
    const { registerGlobals } = await import('@livekit/react-native');
    const { AudioDeviceModule, mediaDevices } =
      await import('@livekit/react-native-webrtc');
    // One-time public media setup. System activation remains exclusively native.
    registerGlobals({ autoConfigureAudioSession: false });
    const initial = await waitForMedia(
      'initial',
      (sample) => !sample.isEngineRunning,
    );
    setConversationHandler(
      handler(async (signal) => {
        const stream = await mediaDevices.getUserMedia({
          audio: true,
          video: false,
        });
        let released = false;
        const release = () => {
          if (released) return 0;
          released = true;
          const tracks = stream.getTracks();
          const failures: unknown[] = [];
          for (const track of tracks) {
            try {
              track.stop();
            } catch (error) {
              failures.push(error);
            }
          }
          try {
            stream.release();
          } catch (error) {
            failures.push(error);
          }
          if (failures.length > 0) throw failures[0];
          return tracks.length;
        };
        const checkOpen = () => {
          if (closing || signal.aborted)
            throw new Error('Example media action cancelled');
        };
        try {
          checkOpen();
          releaseStream = release;
          await trace('m2.localTrack', {
            count: stream.getAudioTracks().length,
            enabled: stream.getAudioTracks()[0].enabled,
          });
          checkOpen();
          // This requests capture on the existing ADM. It neither grants engine
          // availability nor activates AVAudioSession; native LCK is the authority.
          stopRecording = () => AudioDeviceModule.stopLocalRecording();
          await AudioDeviceModule.startLocalRecording();
          checkOpen();
          await trace('m2.recordingDemand', { accepted: true });
          await waitForMedia(
            'demand',
            (sample) =>
              !sample.inputAvailable &&
              !sample.outputAvailable &&
              !sample.isEngineRunning,
            initial,
          );
          checkOpen();
        } catch (error) {
          // Cleanup may already have stopped an in-flight start. Stop again
          // after that start settles so late completion cannot restore demand.
          try {
            if (stopRecording) await stopRecording();
          } finally {
            release();
          }
          throw error;
        }
      }),
    );
    if (stale) await journey().awaitMediaControl();
    await journey().simulatePush(
      JSON.stringify({ incomingCall: payload() }),
      true,
      'primary',
    );
    const ringing = await waitForConversations(
      (snapshot) => snapshot.length === 1 && snapshot[0].status === 'ringing',
    );
    conversationID = ringing[0].id;
    await checkpoint('push-ringing', conversationID);
    await joinConversation(conversationID);
    await waitForConversations(
      (snapshot) =>
        snapshot.length === 1 &&
        snapshot[0]?.id === conversationID &&
        snapshot[0].status === 'connecting' &&
        snapshot[0].pending === undefined &&
        snapshot[0].connectedAt === undefined,
    );
    await checkpoint('joined', conversationID);
    await reportConversation(conversationID, { type: 'connected' });
    await waitForConversations(
      (snapshot) =>
        snapshot.length === 1 &&
        snapshot[0]?.id === conversationID &&
        snapshot[0].status === 'connected' &&
        snapshot[0].pending === undefined &&
        snapshot[0].connectedAt !== undefined,
    );
    await checkpoint('backend-connected', conversationID);
    if (!stale) {
      await waitForMedia(
        'active',
        (sample) => sample.isEngineRunning && sample.activatedCount === 1,
        initial,
      );
      await setHeld(conversationID, true);
      await waitForConversations((snapshot) => snapshot[0]?.status === 'held');
      await waitForMedia(
        'held',
        (sample) => !sample.isEngineRunning && sample.deactivatedCount === 1,
        initial,
      );
      await setHeld(conversationID, false);
      await waitForConversations(
        (snapshot) => snapshot[0]?.status === 'connected',
      );
      await waitForMedia(
        'resumed',
        (sample) => sample.isEngineRunning && sample.activatedCount === 2,
        initial,
      );
      await endConversation(conversationID);
      await waitForConversations((snapshot) => snapshot.length === 0);
      await waitForMedia(
        'ended',
        (sample) => !sample.isEngineRunning && sample.deactivatedCount === 2,
        initial,
      );
      await checkpoint('ended-empty-with-demand', conversationID);
    } else {
      // Observe the SDK's default 10 s activation and 5 s recovery watchdogs.
      // Local demand remains until native failure empties the conversation.
      await waitForMedia(
        'failed',
        (sample) => {
          if (
            sample.inputAvailable ||
            sample.outputAvailable ||
            sample.isEngineRunning
          )
            throw new Error('Example media engine ran without LCK activation');
          return sample.failedCount === 1;
        },
        initial,
        25_000,
      );
      await waitForConversations((snapshot) => snapshot.length === 0);
      await checkpoint('stale-ended-empty-with-demand', conversationID);
    }
    const expectedPublicEvents = stale ? 2 : 4;
    const hookDeadline = Date.now() + 8_000;
    while (
      publicAudioEvents < expectedPublicEvents &&
      Date.now() < hookDeadline
    )
      await sleep(25);
    if (publicAudioEvents !== expectedPublicEvents)
      throw new Error('Example media public audio event deadline');
    success = true;
  } finally {
    closing = true;
    if (!success && conversationID) {
      try {
        await reportConversation(conversationID, {
          type: 'ended',
          reason: 'failed',
        });
      } catch {}
    }
    try {
      await stopRecording?.();
    } catch {
      success = false;
    }
    if (releaseStream) {
      try {
        await trace('m2.localTrackReleased', { count: releaseStream() });
      } catch {
        success = false;
      }
    }
    try {
      setConversationHandler(null);
    } catch {
      success = false;
    }
    await traceQueue.catch(() => {
      success = false;
    });
    await journey().finish(success);
  }
  if (!success) throw new Error('Example media fixture cleanup failed');
}

/** Example-only local media demand; no room/network media quality claim. */
export function runMediaAcceptance(): Promise<void> {
  automaticRun ??= run();
  return automaticRun;
}
