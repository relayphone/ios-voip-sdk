# End an incoming ring when another endpoint answers

When the backend assistant or another endpoint takes a call, the host sends its existing server-call identity:

```ts
const accepted = await receiveCallEnded({
  eventId: 'server-event-123',
  serverCallId: 'server-call-456',
  reason: 'answeredElsewhere',
});
```

Swift uses `client.receiveCallEnded(CallEndedPayload(...))`. A `callEnded` push uses the same native intake. This signal reports LCK `.joinedElsewhere` immediately for the known incoming conversation, without submitting a local End action or waiting for the conversation handler/media cleanup. LCK supplies the underlying system reason equivalent to CallKit's answered-elsewhere reason; the device SDK has no CallKit provider backend.

The boolean reports whether the signal was accepted for a known call. Observe terminal conversation state and the `answeredElsewhere` event for completion. The event contains `conversationId`, `serverCallId` and `eventId`, and follows publication of the terminal SDK snapshot. A duplicate event does not repeat it. A later platform object from an in-flight incoming report receives the retained termination without a second event. Unknown calls and invalid/local signals are refused.

This is an explicit host/server ownership signal. Focus policy does not decide it, and receiving it does not join or answer the local call. The PushKit mandatory-report fallback remains in effect for required pushes.

The simulator journey requires the correlated native reason-4 end report, ended/non-ringing call state, terminal SDK state, event and empty hook within a 1,000 ms engineering budget. This is separate from a physical-device measurement of visible UI dismissal under DND.
