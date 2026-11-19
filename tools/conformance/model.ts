/** Version-zero portable wire records. Identifiers retain their exact application bytes. */
export type WireID = string & { readonly __wireID: unique symbol };
export type Handle = { readonly kind: 'phone'; readonly e164: string }
  | { readonly kind: 'email'; readonly address: string } | { readonly kind: 'opaque'; readonly value: string };
export type Line = Readonly<{ accountID: WireID; id: WireID; label: string }>;
export type Party = Readonly<{ id: WireID; handle: Handle; displayName: string }>;
export type State = 'reporting' | 'ringing' | 'previewing' | 'placing' | 'dialing' | 'connecting'
  | 'connected' | 'reconnecting' | 'ending' | 'ended';
export type Refusal = { readonly kind: 'answeredElsewhere' | 'declinedElsewhere' | 'notAllowed' };
export type Stage = 'placement' | 'claim' | 'reconciliation' | 'mediaPreparation' | 'audioActivation'
  | 'connection' | 'reconnection' | 'systemAction' | 'noAnswer';
export type SystemFailure<Kind = 'admission' | 'start' | 'action' | 'removal' | 'reset' | 'audio'> =
  Readonly<{ platform: 'ios' | 'android'; kind: Kind; code?: number }>;
export type CallError =
  | { readonly kind: 'unknownCall'; readonly callID: WireID }
  | { readonly kind: 'invalidTransition'; readonly state: State }
  | { readonly kind: 'unsupported'; readonly feature: 'hold' | 'video' | 'tones' | 'preview' | 'merge' }
  | { readonly kind: 'permissionRequired'; readonly permission: 'microphone' | 'camera' }
  | { readonly kind: 'refused'; readonly reason: Refusal }
  | { readonly kind: 'authorityUnavailable'; readonly cause: 'credentialsUnavailable' | 'network' | 'invalidResponse' }
  | { readonly kind: 'claimTimedOut'; readonly actionID: WireID }
  | { readonly kind: 'placementFailed'; readonly cause: 'cancelled' | 'handlerFailed' }
  | { readonly kind: 'deadlineExceeded'; readonly stage: Stage }
  | { readonly kind: 'mediaFailed'; readonly stage: 'prepare' | 'activate' | 'release'; readonly cause: 'transport' | 'permission' | 'timeout' }
  | { readonly kind: 'remoteIdentityConflict'; readonly remoteID: WireID }
  | { readonly kind: 'invalidConfiguration'; readonly field: keyof Budgets }
  | { readonly kind: 'systemFailed'; readonly cause: SystemFailure }
  | { readonly kind: 'serverFailed' }
  | { readonly kind: 'bridgeUnavailable' };
export type EndError = Exclude<CallError, { readonly kind: 'refused' }>
  | { readonly kind: 'refused'; readonly reason: { readonly kind: 'notAllowed' } };
export type RemoteEnd = { readonly kind: 'remoteEnded' | 'unanswered' | 'answeredElsewhere' | 'declinedElsewhere' }
  | { readonly kind: 'failed'; readonly error: EndError };
export type EndReason = RemoteEnd | { readonly kind: 'localDeclined' | 'localEnded' }
  | { readonly kind: 'filtered'; readonly cause: 'doNotDisturb' | 'blockList' | 'unknown' };
export type EndReceipt = Readonly<{ callID: WireID; actionID: WireID; reason: { readonly kind: 'localDeclined' | 'localEnded' } }>;
export type EndResult = { readonly kind: 'ended'; readonly receipt: EndReceipt }
  | { readonly kind: 'alreadyEnded'; readonly reason: EndReason };
export type PreviewReason = { readonly kind: 'filtered'; readonly cause: 'doNotDisturb' | 'blockList' | 'unknown' }
  | { readonly kind: 'answeredElsewhere' | 'policy' };
export type Lifecycle = { readonly kind: 'reporting' | 'ringing' | 'placing' | 'dialing' | 'connecting' }
  | { readonly kind: 'previewing'; readonly reason: PreviewReason }
  | { readonly kind: 'connected' | 'reconnecting'; readonly connectedAt: string }
  | { readonly kind: 'ending'; readonly reason: EndReason }
  | { readonly kind: 'ended'; readonly reason: EndReason; readonly endedAt: string };
export type Media = Readonly<{ owner: 'native' | 'application'; preparation: 'unprovided' | 'preparing' | 'prepared' | 'released';
  audio: 'inactive' | 'active'; transport: 'disconnected' | 'connecting' | 'connected' | 'reconnecting' }>;
export type Call = Readonly<{ id: WireID; remoteID?: WireID; line: Line; direction: 'incoming' | 'outgoing';
  parties: readonly [Party, ...Party[]]; lifecycle: Lifecycle; held: boolean; muted: boolean; video: boolean; media: Media }>;
export type Invitation = Readonly<{ callID: WireID; eventID: WireID; line: Line; party: Party }>;
export type DTMFDigit = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' | '*' | '#';
export type Action = { readonly kind: 'start'; readonly callID: WireID; readonly line: Line; readonly party: Party }
  | { readonly kind: 'answer' | 'join' | 'end'; readonly callID: WireID }
  | { readonly kind: 'hold'; readonly callID: WireID; readonly held: boolean }
  | { readonly kind: 'mute'; readonly callID: WireID; readonly muted: boolean }
  | { readonly kind: 'video'; readonly callID: WireID; readonly enabled: boolean }
  | { readonly kind: 'tones'; readonly callID: WireID; readonly digits: readonly [DTMFDigit, ...DTMFDigit[]] };
export type Budgets = Readonly<{ answer: Readonly<{ total: number; claim: number; reconciliation: number; settlementReserve: number }>;
  placement: number; incomingRing: number; outgoingNoAnswer: number; mediaPreparation: number;
  audioActivation: number; audioRecovery: number; connection: number; reconnection: number;
  retention?: Readonly<{ lifetime: number; terminalRecords: number }> }>;
export type Model = { readonly version: 0 } & (
  | { readonly kind: 'call'; readonly value: Call } | { readonly kind: 'action'; readonly value: Action }
  | { readonly kind: 'endReason'; readonly value: EndReason } | { readonly kind: 'error'; readonly value: CallError }
  | { readonly kind: 'endResult'; readonly value: EndResult }
  | { readonly kind: 'budgets'; readonly value: Budgets });
export type Configuration = Readonly<{ budgets: Budgets; outgoingMedia: 'whenProvided' | 'duringPlacement';
  connectionAuthority: 'application' | 'nativeMedia'; maximumParticipatingCalls: 1; previewAnsweredElsewhere: boolean }>;
export type AuthorityDecision = { readonly kind: 'allow' } | { readonly kind: 'refuse'; readonly reason: Refusal };
export type Input = { readonly kind: 'process'; readonly running: boolean; readonly javascriptAttached: boolean }
  | ({ readonly kind: 'incoming'; readonly deferAdmission?: true } & Invitation)
  | { readonly kind: 'authority'; readonly callID: WireID; readonly claim: AuthorityDecision | { readonly kind: 'timeout' };
      readonly reconciliation: AuthorityDecision | { readonly kind: 'unknown' } }
  | ({ readonly kind: 'action'; readonly origin: 'app' | 'system' } & (
      | { readonly action: Action; readonly deferConfirmation?: never }
      | { readonly action: Extract<Action, { readonly kind: 'hold' }>; readonly deferConfirmation: true }))
  | { readonly kind: 'provideMedia' | 'admitted' | 'latePermit' | 'holdApplied'; readonly callID: WireID }
  | { readonly kind: 'placed'; readonly callID: WireID; readonly deferStartAdmission?: true }
  | { readonly kind: 'startAdmitted'; readonly callID: WireID; readonly stale?: true }
  | { readonly kind: 'startFailed'; readonly callID: WireID; readonly failure: SystemFailure<'start'> }
  | { readonly kind: 'admissionFailed'; readonly callID: WireID; readonly failure: SystemFailure<'admission'> }
  | { readonly kind: 'bindRemote'; readonly callID: WireID; readonly remoteID: WireID }
  | { readonly kind: 'connected'; readonly callID: WireID; readonly eventID: WireID }
  | { readonly kind: 'remoteEnd'; readonly target: { readonly kind: 'call' | 'remote'; readonly id: WireID }; readonly eventID: WireID; readonly reason: RemoteEnd }
  | { readonly kind: 'advance'; readonly milliseconds: number };
export type Metric = 'claims' | 'reconciliations' | 'settlements' | 'publications' | 'activations' | 'reports' | 'placements'
  | 'performedEnds' | 'releases' | 'claimTimeouts' | 'permitReleases' | 'ringingPublications' | 'holdRequests';
export type EndExpectation = Exclude<EndReason, { readonly kind: 'failed' }>
  | { readonly kind: 'failed'; readonly error: CallError['kind'] };
export type LifecycleExpectation = { readonly kind: Exclude<State, 'previewing' | 'ending' | 'ended'> }
  | { readonly kind: 'previewing'; readonly reason: PreviewReason }
  | { readonly kind: 'ending' | 'ended'; readonly reason: EndExpectation };
export type ErrorExpectation = { readonly error: Exclude<CallError['kind'], 'refused'> }
  | { readonly error: 'refused'; readonly reason?: Refusal };
export type Expectation = { readonly kind: 'call'; readonly callID: WireID; readonly lifecycle: LifecycleExpectation; readonly lineID?: WireID; readonly remoteID?: WireID; readonly held?: boolean; readonly muted?: boolean }
  | { readonly kind: 'count'; readonly callID: WireID; readonly metric: Metric; readonly value: number }
  | { readonly kind: 'participating'; readonly callIDs: readonly WireID[] }
  | { readonly kind: 'systemEnd'; readonly callID: WireID; readonly cause: 'local' | 'remote' | 'missed' | 'rejected' }
  | { readonly kind: 'endResult'; readonly callID: WireID; readonly result: EndResult }
  | ({ readonly kind: 'error'; readonly callID: WireID } & ErrorExpectation);
export type Journey = Readonly<{ version: 0; id: WireID; configuration: Configuration;
  steps: readonly ({ readonly kind: 'input'; readonly input: Input } | { readonly kind: 'expect'; readonly expectation: Expectation })[] }>;
export type Trigger = 'incoming' | 'admitted' | 'start' | 'placed' | 'answer' | 'claimExpired' | 'authorityAllowed'
  | 'admissionFailed' | 'startAdmitted' | 'startFailed' | 'systemSetupResult' | 'outgoingProgress' | 'terminalIntent'
  | 'mediaPrepared' | 'answerRefused' | 'reconciliationUnknown' | 'connected' | 'provideMedia' | 'bindRemote'
  | 'mediaReleased' | 'join' | 'transportLost' | 'transportRecovered' | 'deadlineExpired' | 'frameworkReset' | 'joinFailed' | 'mediaFailed'
  | 'noAnswerExpired' | 'hold' | 'mute' | 'video' | 'tones' | 'localEnd' | 'remoteEnd' | 'systemRemoved' | 'lateCompletion'
  | 'holdApplied' | 'muteApplied' | 'videoApplied' | 'tonesApplied' | 'holdFailed' | 'muteFailed' | 'videoFailed' | 'tonesFailed';
export type Guard = 'newCall' | 'newCallAndSlot' | 'joinEligible' | 'outgoingDeferred' | 'outgoingEager' | 'outgoingPrepared' | 'preparedJoin' | 'noAnswerPending' | 'incomingJoin' | 'answerEligible' | 'notReconciled'
  | 'currentAttempt' | 'authorizedAnswerPending' | 'authoritativeAndPrepared' | 'mediaNotReady' | 'bufferedConnected'
  | 'live' | 'aliasAvailable' | 'supported' | 'firstTerminalIntent' | 'previewPolicy' | 'mediaReleased' | 'always'
  | 'elsewhereRefusalPreview' | 'elsewhereRefusal' | 'notAllowedRefusal' | 'retainedEnd' | 'retainedEndPreview'
  | 'hasLocalEndReceipt' | 'staleAttempt' | 'noToneTransport' | 'noRetainedEnd'
  | 'startAdmissionPending' | 'bufferedStartProgress' | 'retiringStart';
export type Effect = 'reserveIdentity' | 'reportIncoming' | 'publish' | 'requestPlacement' | 'nativeStart' | 'requestClaim'
  | 'reconcile' | 'prepareMedia' | 'settleAction' | 'rejectAction' | 'closeMedia' | 'requestRemoval' | 'setActive'
  | 'armConnection' | 'bufferProgress' | 'applyBufferedProgress' | 'bindAlias' | 'drainEvents' | 'applyHold' | 'applyMute' | 'applyVideo'
  | 'returnOriginalEnd' | 'returnAlreadyEnded' | 'armReconnection' | 'restorePreview' | 'ignore'
  | 'trackAction' | 'sendTones' | 'retainEnd' | 'bufferEnd' | 'retainBufferedEnd' | 'emitObservation' | 'releasePermit';
export type Transition = Readonly<{ id: WireID; from: readonly (State | 'absent')[]; input: Trigger;
  guard: Guard; to: State | 'same' | 'absent'; effects: readonly Effect[] }>;
export type Transitions = Readonly<{ version: 0; rules: readonly Transition[] }>;
