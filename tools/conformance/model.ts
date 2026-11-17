/** Version-zero portable wire records. Identifiers retain their exact application bytes. */
export type Handle = { readonly kind: 'phone'; readonly e164: string }
  | { readonly kind: 'email'; readonly address: string } | { readonly kind: 'opaque'; readonly value: string };
export type Line = Readonly<{ accountID: string; id: string; label: string }>;
export type Party = Readonly<{ id: string; handle: Handle; displayName: string }>;
export type State = 'reporting' | 'ringing' | 'previewing' | 'placing' | 'dialing' | 'connecting'
  | 'connected' | 'reconnecting' | 'ending' | 'ended';
export type Refusal = { readonly kind: 'answeredElsewhere' | 'declinedElsewhere' | 'notAllowed' };
export type Stage = 'placement' | 'claim' | 'reconciliation' | 'mediaPreparation' | 'audioActivation'
  | 'connection' | 'reconnection' | 'systemAction' | 'noAnswer';
export type CallError =
  | { readonly kind: 'unknownCall'; readonly callID: string }
  | { readonly kind: 'invalidTransition'; readonly state: State }
  | { readonly kind: 'unsupported'; readonly feature: 'hold' | 'video' | 'tones' | 'preview' | 'merge' }
  | { readonly kind: 'permissionRequired'; readonly permission: 'microphone' | 'camera' }
  | { readonly kind: 'refused'; readonly reason: Refusal }
  | { readonly kind: 'authorityUnavailable'; readonly cause: 'credentialsUnavailable' | 'network' | 'invalidResponse' }
  | { readonly kind: 'claimTimedOut'; readonly actionID: string }
  | { readonly kind: 'placementFailed'; readonly cause: 'cancelled' | 'handlerFailed' }
  | { readonly kind: 'deadlineExceeded'; readonly stage: Stage }
  | { readonly kind: 'mediaFailed'; readonly stage: 'prepare' | 'activate' | 'release'; readonly cause: 'transport' | 'permission' | 'timeout' }
  | { readonly kind: 'remoteIdentityConflict'; readonly remoteID: string }
  | { readonly kind: 'invalidConfiguration'; readonly field: keyof Budgets }
  | { readonly kind: 'systemFailed'; readonly cause: Readonly<{ platform: 'ios' | 'android'; kind: 'admission' | 'action' | 'removal' | 'reset' | 'audio'; code?: number }> }
  | { readonly kind: 'bridgeUnavailable' };
export type RemoteEnd = { readonly kind: 'remoteEnded' | 'unanswered' | 'answeredElsewhere' | 'declinedElsewhere' }
  | { readonly kind: 'failed'; readonly error: CallError };
export type EndReason = RemoteEnd | { readonly kind: 'localDeclined' | 'localEnded' }
  | { readonly kind: 'filtered'; readonly cause: 'doNotDisturb' | 'blockList' | 'unknown' };
export type PreviewReason = { readonly kind: 'filtered'; readonly cause: 'doNotDisturb' | 'blockList' | 'unknown' }
  | { readonly kind: 'answeredElsewhere' | 'policy' };
export type Lifecycle = { readonly kind: 'reporting' | 'ringing' | 'placing' | 'dialing' | 'connecting' }
  | { readonly kind: 'previewing'; readonly reason: PreviewReason }
  | { readonly kind: 'connected' | 'reconnecting'; readonly connectedAt: string }
  | { readonly kind: 'ending'; readonly reason: EndReason }
  | { readonly kind: 'ended'; readonly reason: EndReason; readonly endedAt: string };
export type Media = Readonly<{ owner: 'native' | 'application'; preparation: 'unprovided' | 'preparing' | 'prepared' | 'released';
  audio: 'inactive' | 'active'; transport: 'disconnected' | 'connecting' | 'connected' | 'reconnecting' }>;
export type Call = Readonly<{ id: string; remoteID?: string; line: Line; direction: 'incoming' | 'outgoing';
  parties: readonly [Party, ...Party[]]; lifecycle: Lifecycle; held: boolean; muted: boolean; video: boolean; media: Media }>;
export type Invitation = Readonly<{ callID: string; eventID: string; line: Line; party: Party }>;
export type DTMFDigit = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' | '*' | '#';
export type Action = { readonly kind: 'start'; readonly callID: string; readonly line: Line; readonly party: Party }
  | { readonly kind: 'answer' | 'join' | 'end'; readonly callID: string }
  | { readonly kind: 'hold'; readonly callID: string; readonly held: boolean }
  | { readonly kind: 'mute'; readonly callID: string; readonly muted: boolean }
  | { readonly kind: 'video'; readonly callID: string; readonly enabled: boolean }
  | { readonly kind: 'tones'; readonly callID: string; readonly digits: readonly [DTMFDigit, ...DTMFDigit[]] };
export type Budgets = Readonly<{ answer: Readonly<{ total: number; claim: number; reconciliation: number; settlementReserve: number }>;
  placement: number; incomingRing: number; outgoingNoAnswer: number; mediaPreparation: number;
  audioActivation: number; audioRecovery: number; connection: number; reconnection: number }>;
export type Model = { readonly version: 0 } & (
  | { readonly kind: 'call'; readonly value: Call } | { readonly kind: 'action'; readonly value: Action }
  | { readonly kind: 'endReason'; readonly value: EndReason } | { readonly kind: 'error'; readonly value: CallError }
  | { readonly kind: 'budgets'; readonly value: Budgets });
export type Configuration = Readonly<{ budgets: Budgets; outgoingMedia: 'whenProvided' | 'duringPlacement';
  connectionAuthority: 'application' | 'nativeMedia'; maximumParticipatingCalls: 1; previewAnsweredElsewhere: boolean }>;
export type AuthorityDecision = { readonly kind: 'allow' } | { readonly kind: 'refuse'; readonly reason: Refusal };
export type Input = { readonly kind: 'process'; readonly running: boolean; readonly javascriptAttached: boolean }
  | ({ readonly kind: 'incoming' } & Invitation)
  | { readonly kind: 'authority'; readonly callID: string; readonly claim: AuthorityDecision | { readonly kind: 'timeout' };
      readonly reconciliation: AuthorityDecision | { readonly kind: 'unknown' } }
  | { readonly kind: 'action'; readonly origin: 'app' | 'system'; readonly action: Action }
  | { readonly kind: 'placed' | 'provideMedia'; readonly callID: string }
  | { readonly kind: 'bindRemote'; readonly callID: string; readonly remoteID: string }
  | { readonly kind: 'connected'; readonly callID: string; readonly eventID: string }
  | { readonly kind: 'remoteEnd'; readonly target: { readonly kind: 'call' | 'remote'; readonly id: string }; readonly eventID: string; readonly reason: RemoteEnd }
  | { readonly kind: 'advance'; readonly milliseconds: number };
export type Metric = 'claims' | 'reconciliations' | 'settlements' | 'publications' | 'activations' | 'reports' | 'placements' | 'performedEnds' | 'releases';
export type EndExpectation = Exclude<EndReason, { readonly kind: 'failed' }>
  | { readonly kind: 'failed'; readonly error: CallError['kind'] };
export type LifecycleExpectation = { readonly kind: Exclude<State, 'previewing' | 'ending' | 'ended'> }
  | { readonly kind: 'previewing'; readonly reason: PreviewReason }
  | { readonly kind: 'ending' | 'ended'; readonly reason: EndExpectation };
export type Expectation = { readonly kind: 'call'; readonly callID: string; readonly lifecycle: LifecycleExpectation; readonly lineID?: string; readonly remoteID?: string; readonly held?: boolean; readonly muted?: boolean }
  | { readonly kind: 'count'; readonly callID: string; readonly metric: Metric; readonly value: number }
  | { readonly kind: 'participating'; readonly callIDs: readonly string[] }
  | { readonly kind: 'systemEnd'; readonly callID: string; readonly cause: 'local' | 'remote' | 'missed' | 'rejected' }
  | { readonly kind: 'error'; readonly callID: string; readonly error: CallError['kind'] };
export type Journey = Readonly<{ version: 0; id: string; configuration: Configuration;
  steps: readonly ({ readonly kind: 'input'; readonly input: Input } | { readonly kind: 'expect'; readonly expectation: Expectation })[] }>;
export type Trigger = 'incoming' | 'admitted' | 'start' | 'placed' | 'answer' | 'claimExpired' | 'authorityAllowed'
  | 'mediaPrepared' | 'answerRefused' | 'reconciliationUnknown' | 'connected' | 'provideMedia' | 'bindRemote'
  | 'mediaReleased' | 'join' | 'transportLost' | 'transportRecovered' | 'deadlineExpired' | 'frameworkReset' | 'joinFailed' | 'mediaFailed'
  | 'noAnswerExpired' | 'hold' | 'mute' | 'video' | 'localEnd' | 'remoteEnd' | 'systemRemoved' | 'lateCompletion';
export type Guard = 'newCall' | 'newCallAndSlot' | 'joinEligible' | 'noRetainedEnd' | 'outgoingDeferred' | 'outgoingEager' | 'outgoingPrepared' | 'preparedJoin' | 'noAnswerPending' | 'incomingJoin' | 'answerEligible' | 'notReconciled'
  | 'currentAttempt' | 'authorizedAnswerPending' | 'authoritativeAndPrepared' | 'mediaNotReady' | 'bufferedConnected'
  | 'live' | 'aliasAvailable' | 'supported' | 'firstTerminalIntent' | 'previewPolicy' | 'mediaReleased' | 'always';
export type Effect = 'reserveIdentity' | 'reportIncoming' | 'publish' | 'requestPlacement' | 'nativeStart' | 'requestClaim'
  | 'reconcile' | 'prepareMedia' | 'settleAction' | 'rejectAction' | 'closeMedia' | 'requestRemoval' | 'setActive'
  | 'armConnection' | 'bufferProgress' | 'bindAlias' | 'drainEvents' | 'applyHold' | 'applyMute' | 'applyVideo'
  | 'returnOriginalEnd' | 'armReconnection' | 'restorePreview' | 'ignore';
export type Transition = Readonly<{ id: string; from: readonly (State | 'absent')[]; input: Trigger;
  guard: Guard; to: State | 'same' | 'absent'; effects: readonly Effect[] }>;
export type Transitions = Readonly<{ version: 0; rules: readonly Transition[] }>;
