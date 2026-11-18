import { useSyncExternalStore } from 'react';
import type { CallID } from './model.ts';
import type { CallsStore } from './store.ts';

/** The native client binds these hooks once to its store. */
export function createCallsHooks(store: CallsStore) {
  const subscribe = (changed: () => void) => store.subscribe(changed);
  const calls = () => store.snapshot().calls;
  const pushHealth = () => store.snapshot().pushHealth;
  return {
    useCalls: () => useSyncExternalStore(subscribe, calls, calls),
    useCall(id: CallID) {
      const read = () => calls().find(call => call.id === id);
      return useSyncExternalStore(subscribe, read, read);
    },
    usePushHealth: () => useSyncExternalStore(subscribe, pushHealth, pushHealth),
  };
}
