import { requireNativeModule, type NativeModule } from 'expo';

import { ConversationRuntime } from './client';
import type { NativeBridge, NativeEvents } from './protocol';

const runtimeKey = Symbol.for('ios-voip-sdk.conversation-runtime');

/** Keep native subscriptions and in-flight handlers across Fast Refresh. */
export function getRuntime(): ConversationRuntime {
  const existing = Reflect.get(globalThis, runtimeKey) as
    ConversationRuntime | undefined;
  if (existing !== undefined) return existing;
  const bridge = requireNativeModule<NativeModule<NativeEvents> & NativeBridge>(
    'IosVoipSDK',
  );
  const runtime = new ConversationRuntime(bridge);
  Object.defineProperty(globalThis, runtimeKey, {
    value: runtime,
    configurable: true,
  });
  return runtime;
}
