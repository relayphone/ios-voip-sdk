import type { ActionContext, ConversationHandler } from '../types';
import type {
  ActionCancellation,
  HandlerAction,
  NativeBridge,
} from './protocol';

export class HandlerDispatcher {
  private generation = 0;
  private handler: ConversationHandler | null = null;
  private readonly running = new Map<string, AbortController>();

  constructor(
    private readonly bridge: Pick<
      NativeBridge,
      'setHandlerAttached' | 'settleAction'
    >,
  ) {}

  setHandler(handler: ConversationHandler | null): void {
    this.generation += 1;
    const generation = this.generation;
    this.handler = handler;
    const previous = [...this.running.values()];
    this.running.clear();
    for (const controller of previous) controller.abort('handlerReplaced');
    // Abort listeners run app code synchronously and may install a newer handler.
    if (generation !== this.generation) return;
    try {
      this.bridge.setHandlerAttached(handler !== null, generation);
    } catch (error) {
      if (generation === this.generation) this.handler = null;
      throw error;
    }
  }

  dispatch(action: HandlerAction): void {
    const handler = this.handler;
    if (
      handler === null ||
      action.generation !== this.generation ||
      this.running.has(action.actionID)
    ) {
      return;
    }
    const controller = new AbortController();
    this.running.set(action.actionID, controller);
    const context: ActionContext = {
      deadline: action.deadline,
      origin: action.origin,
      signal: controller.signal,
    };

    void Promise.resolve()
      .then(() => {
        if (!this.isCurrent(action, controller)) return;
        switch (action.kind) {
          case 'hold':
            return handler.hold?.(action.conversation, {
              ...context,
              held: action.held,
            });
          case 'mute':
            return handler.mute?.(action.conversation, {
              ...context,
              muted: action.muted,
            });
          case 'tones':
            return handler.tones?.(action.conversation, {
              ...context,
              digits: action.digits,
            });
          default:
            return handler[action.kind](action.conversation, context);
        }
      })
      .then(
        () => this.settle(action, controller, true),
        (error: unknown) => this.settle(action, controller, false, error),
      )
      .catch(() => {
        // Native owns expiry and cancellation even if its bridge is gone.
        console.warn('ios-voip-sdk: conversation action settlement failed.');
      });
  }

  cancel(action: ActionCancellation): void {
    if (action.generation !== this.generation) return;
    const controller = this.running.get(action.actionID);
    this.running.delete(action.actionID);
    controller?.abort(action.reason);
  }

  private isCurrent(
    action: HandlerAction,
    controller: AbortController,
  ): boolean {
    return (
      action.generation === this.generation &&
      this.running.get(action.actionID) === controller &&
      !controller.signal.aborted
    );
  }

  private settle(
    action: HandlerAction,
    controller: AbortController,
    success: boolean,
    error?: unknown,
  ): void {
    if (!this.isCurrent(action, controller)) return;
    this.running.delete(action.actionID);
    const failure = success
      ? undefined
      : error instanceof Error
        ? { name: error.name, message: error.message }
        : {
            name: 'Error',
            message:
              typeof error === 'string'
                ? error
                : 'The conversation handler failed.',
          };
    this.bridge.settleAction(
      action.actionID,
      action.generation,
      success,
      failure,
    );
  }
}
