import { useEffect, useRef, useSyncExternalStore } from "react";

import bridge from "./VoIPConversationsModule";
import {
  HandlerDispatcher,
  RevisionStore,
  reconcile,
} from "./conversations/runtime";
import type { ConversationEvent } from "./conversations/transport";
import type {
  AudioRoutes,
  CallPreviewActivities,
  Conversation,
  ConversationEventMap,
  ConversationHandler,
  ConversationId,
  FocusFilterState,
  PushToken,
} from "./conversations/types";

class Runtime {
  readonly conversations = new RevisionStore<readonly Conversation[]>([]);
  readonly routes = new RevisionStore<AudioRoutes>({
    routes: [],
    current: null,
  });
  readonly token = new RevisionStore<PushToken | null>(null);
  readonly previews = new RevisionStore<CallPreviewActivities | null>(null);
  readonly focus = new RevisionStore<FocusFilterState | null>(null);
  readonly handler = new HandlerDispatcher(bridge);
  constructor() {
    bridge.addListener("conversationsChanged", (event) =>
      this.update(event.revision, event.conversations)
    );
    bridge.addListener("audioRoutesChanged", (event) =>
      this.routes.accept(event.revision, event)
    );
    bridge.addListener("pushTokenUpdated", (event) =>
      this.token.accept(event.revision, event.token)
    );
    bridge.addListener("handlerAction", (event) =>
      this.handler.dispatch(event)
    );
    bridge.addListener("actionCancelled", (event) =>
      this.handler.cancel(event.actionID, event.generation, event.reason)
    );
    const snapshot = bridge.snapshot;
    this.update(snapshot.revision, snapshot.conversations);
    this.read().catch(this.conversations.fail.bind(this.conversations));
    bridge
      .getAudioRoutes()
      .then((event) => this.routes.accept(event.revision, event))
      .catch(this.routes.fail.bind(this.routes));
    bridge
      .getPushToken()
      .then((event) => this.token.accept(event.revision, event.token))
      .catch(this.token.fail.bind(this.token));
    // Android has no call preview Live Activities.
    if (bridge.getCallPreviewActivities) {
      bridge.addListener("callPreviewActivitiesChanged", (event) =>
        this.previews.accept(event.revision, event.activities)
      );
      this.readPreviews().catch(this.previews.fail.bind(this.previews));
    }
    // Android has no Focus filter state.
    if (bridge.getFocusFilterState) {
      bridge.addListener("focusFilterStateChanged", (event) =>
        this.focus.accept(event.revision, event.state)
      );
      this.readFocus().catch(this.focus.fail.bind(this.focus));
    }
  }
  async readFocus() {
    if (!bridge.getFocusFilterState) return null;
    const event = await bridge.getFocusFilterState();
    this.focus.accept(event.revision, event.state);
    return this.focus.read();
  }
  async readPreviews() {
    if (!bridge.getCallPreviewActivities) return null;
    const event = await bridge.getCallPreviewActivities();
    this.previews.accept(event.revision, event.activities);
    return this.previews.read();
  }
  private update(
    revision: number,
    conversations: readonly Conversation[]
  ) {
    this.conversations.accept(
      revision,
      reconcile(this.conversations.peek(), conversations)
    );
  }
  async read() {
    const event = await bridge.getConversations();
    this.update(event.revision, event.conversations);
    return this.conversations.read();
  }
}
// SAFETY: This shared registry slot is initialized only with the runtime for this native bridge.
const registry = globalThis as typeof globalThis & {
  __expoConversationsRuntime?: Runtime;
};
const runtime = registry.__expoConversationsRuntime ?? new Runtime();
registry.__expoConversationsRuntime = runtime;

/** Complete current conversation list, including native cold-launch state. @category State */
export const getConversations = () =>
  runtime.read();
/** Subscribe to immutable system state. @category Hooks */
export function useConversations() {
  return useSyncExternalStore(
    runtime.conversations.subscribe,
    runtime.conversations.read
  );
}
/** Subscribe to one stable conversation object. @category Hooks */
export function useConversation(id: ConversationId) {
  return useSyncExternalStore(runtime.conversations.subscribe, () =>
    runtime.conversations.read().find((conversation) => conversation.id === id)
  );
}
/** Native audio endpoints and the actual current output. @category Hooks */
export function useAudioRoutes() {
  return useSyncExternalStore(runtime.routes.subscribe, runtime.routes.read);
}
/** Current native push registration, or null. @category Hooks */
export function usePushToken() {
  return useSyncExternalStore(runtime.token.subscribe, runtime.token.read);
}
/**
 * iOS, with the `callPreviewActivities` plugin option: the tokens and authorization that the app's
 * servers need to start, update and end call previews' Live Activities. Null on Android and
 * without the option. @category Call previews
 */
export const getCallPreviewActivities =
  () => runtime.readPreviews();
/**
 * Subscribe to what the app's servers need for call previews' Live Activities; send each change
 * to them. Null on Android and without the `callPreviewActivities` plugin option.
 * @category Hooks
 */
export function useCallPreviewActivities() {
  return useSyncExternalStore(
    runtime.previews.subscribe,
    runtime.previews.read
  );
}
/**
 * iOS, with the `focusFilter` plugin option: what the app's Focus filter last asked for. Null on
 * Android and without the option. @category Focus
 */
export const getFocusFilterState = () =>
  runtime.readFocus();
/**
 * Subscribe to the app's Focus filter state, which changes when a Focus that has the filter turns
 * on or off, even while the app isn't running; send each change to the app's servers. Null on
 * Android and without the `focusFilter` plugin option.
 * @category Hooks
 */
export function useFocusFilterState() {
  return useSyncExternalStore(runtime.focus.subscribe, runtime.focus.read);
}
/** Register at module scope before React mounts; null detaches and cancels old work. @category Handler */
export function setConversationHandler(
  handler: ConversationHandler | null
) {
  runtime.handler.set(handler);
}
type HookEvent = ConversationEvent | {
  type: "pushTokenUpdated";
  payload: ConversationEventMap["pushTokenUpdated"];
};

function matchesEvent<Name extends keyof ConversationEventMap>(
  event: HookEvent,
  name: Name
): event is HookEvent & { type: Name; payload: ConversationEventMap[Name] } {
  return event.type === name;
}

/** Lifecycle signals that cannot be derived from state. @category Hooks */
export function useConversationEvent<Name extends keyof ConversationEventMap>(
  name: Name,
  listener: (event: ConversationEventMap[Name]) => void
) {
  const callback = useRef(listener);
  useEffect(() => {
    callback.current = listener;
  }, [listener]);
  useEffect(() => {
    const deliver = (event: HookEvent) => {
      if (matchesEvent(event, name)) callback.current(event.payload);
    };
    if (name === "pushTokenUpdated")
      return runtime.token.subscribe(() =>
        deliver({ type: "pushTokenUpdated", payload: runtime.token.read() })
      );
    const subscription = bridge.addListener("conversationEvent", deliver);
    return () => subscription.remove();
  }, [name]);
}
/** App → system commands. @category Commands */
export const startConversation = bridge.startConversation.bind(bridge);
export const joinConversation = bridge.joinConversation.bind(bridge);
export const endConversation = bridge.endConversation.bind(bridge);
export const setHeld = bridge.setHeld.bind(bridge);
/**
 * Ask the system to change whether a call carries video; never requests camera permission.
 * Resolves after reporting to the platform, then snapshots show isVideo and videoChanged fires.
 * Rejects unsupported, unknown_conversation, or invalid_arguments for an ended conversation.
 * Same-value calls are no-ops; check conversationMediaReadiness before starting a camera track.
 * @category Commands
 */
export const setConversationVideo = bridge.setConversationVideo.bind(bridge);
export const setMuted = bridge.setMuted.bind(bridge);
export const playTones = bridge.playTones.bind(bridge);
export const mergeConversations = bridge.mergeConversations.bind(bridge);
/** Transport → system reports. @category Reports */
export const reportIncomingConversation =
  bridge.reportIncomingConversation.bind(bridge);
export const reportConversation = bridge.reportConversation.bind(bridge);
/** Accept a backend/host end signal for a known incoming conversation. @category Reports */
export const receiveCallEnded = bridge.receiveCallEnded.bind(bridge);
/** Request an available native endpoint. @category Audio */
export const selectAudioRoute = bridge.selectAudioRoute.bind(bridge);

/** Read both media permissions without prompting, including in background paths. @category Permissions */
export const getMediaPermissions = bridge.getMediaPermissions.bind(bridge);
/** Explicit foreground-only prompts for permissions that can still be asked. @category Permissions */
export const requestMediaPermissions = bridge.requestMediaPermissions.bind(bridge);
/** Read the required and missing permissions for a conversation without prompting. @category Permissions */
export const conversationMediaReadiness = bridge.conversationMediaReadiness.bind(bridge);
