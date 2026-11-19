package com.relayphone.voip

import java.util.Collections
import kotlin.time.Duration
import kotlin.time.Instant

/** Applies one input with separate elapsed time and UTC samples. Effects retain their order. */
public fun reduce(state: State, input: Input, now: Now): Transition =
    reduce(state, input, now) {}

/** Applies one input while keeping terminals with outstanding adapter jobs out of retention. */
public fun reduce(state: State, input: Input, now: Now, pendingAdapterWork: Set<CallID>): Transition =
    Reduction(state, now, {}, pendingAdapterWork).run(input)

internal fun reduce(state: State, input: Input, now: Now, trace: (Rule) -> Unit): Transition =
    Reduction(state, now, trace, emptySet()).run(input)

private class Reduction(
    state: State, private val clocks: Now, private val trace: (Rule) -> Unit,
    private val pendingAdapterWork: Set<CallID>,
) {
    private val now = clocks.monotonic
    private val policy = state.configuration
    private val budgets = policy.budgets
    private val retention = budgets.retention
    private var records = state.records
    private var events = state.events.filterValues { withinRetention(it.at) }
    private var releasedPermits = state.releasedPermits.filterValues(::withinRetention)
    private var actionIDs = state.actionIDs.filterValues(::withinRetention)
    private var generation = state.generation
    private var completed = state.completedTerminalCalls
    private val terminalCompletions = mutableListOf<CallID>()
    private var receipt: CommandReceipt? = null
    private var admission: AdmissionCompletion? = null
    private var removal: RemovalCompletion? = null
    private val effects = mutableListOf<Effect>()

    fun run(input: Input): Transition {
        prune()
        when (input) {
            is Input.Incoming -> receipt = incoming(input)
            is Input.Admitted -> admitted(input)
            is Input.AdmissionFailed -> admissionFailed(input)
            is Input.StartAdmitted -> startAdmitted(input)
            is Input.StartFailed -> startFailed(input)
            is Input.Request -> request(input)
            is Input.Start -> start(input)
            is Input.Placed -> receipt = CommandReceipt.Placement(placed(input))
            is Input.JoinPlacementLost -> on(input.attempt) { record ->
                if (record.call.lifecycle == Lifecycle.Connecting && record.joinAttempt == input.attempt &&
                    !expireDue(record, TimerKind.CONNECTION)
                ) {
                    trace(Rule.JOIN_FAILED)
                    failAttempt(record, input.error)
                }
            }
            is Input.AuthorityAllowed -> allowed(input)
            is Input.AnswerRefused -> answerRefused(input)
            is Input.ReconciliationUnknown -> on(input.attempt) { record ->
                val answer = record.answer ?: return@on
                if (record.reconciliation == input.attempt && record.permit == null) {
                    trace(Rule.CLAIM_UNRESOLVED)
                    val error = CallError.ClaimTimedOut(answer.id)
                    finish(record, EndReason.Failed(error), error)
                }
            }
            is Input.ProvideMedia -> records[input.id]?.let(::provideMedia)
            is Input.MediaPrepared -> prepared(input)
            is Input.MediaFailed -> on(input.attempt) { record ->
                if (record.live && record.mediaAttempt == input.attempt) {
                    trace(if (record.previousPreview != null) Rule.JOIN_MEDIA_FAILED else Rule.MEDIA_FAILED)
                    failAttempt(record, input.error)
                }
            }
            is Input.Connected -> connected(input)
            is Input.BindRemote -> {
                val outcome = bind(input)
                if (outcome is Outcome.Failure) reject(input.callID, null, outcome.error)
                receipt = CommandReceipt.Bound(outcome)
            }
            is Input.Receive -> receipt = CommandReceipt.Received(receive(input.event))
            is Input.RemoteEnd -> receive(RemoteEvent.Ended(input.eventID, input.target, input.reason))
            is Input.Applied -> controlResult(input.attempt, null)
            is Input.ApplyFailed -> controlResult(input.attempt, input.error)
            is Input.TimerExpired -> expired(input)
            is Input.TransportLost -> on(input.attempt) { record ->
                val connected = record.call.lifecycle as? Lifecycle.Connected ?: return@on
                if (record.mediaAttempt == input.attempt) {
                    trace(Rule.TRANSPORT_LOST)
                    val recovering = record.copy(call = record.call.copy(
                        lifecycle = Lifecycle.Reconnecting(connected.connectedAt),
                        media = record.call.media.copy(transport = Transport.RECONNECTING),
                    ))
                    put(arm(recovering, TimerKind.RECONNECTION, now + budgets.reconnection), publish = true)
                }
            }
            is Input.TransportRecovered -> on(input.attempt) { record ->
                val recovering = record.call.lifecycle as? Lifecycle.Reconnecting ?: return@on
                if (record.timers[TimerKind.RECONNECTION]?.attempt == input.attempt &&
                    !expireDue(record, TimerKind.RECONNECTION)
                ) {
                    trace(Rule.TRANSPORT_RECOVERED)
                    val recovered = cancel(record, TimerKind.RECONNECTION)
                    put(recovered.copy(call = recovered.call.copy(
                        lifecycle = Lifecycle.Connected(recovering.connectedAt),
                        media = recovered.call.media.copy(transport = Transport.CONNECTED),
                    )), publish = true)
                }
            }
            is Input.MediaReleased -> mediaReleased(input.attempt)
            is Input.SystemRemoved -> removalCompleted(input.attempt, removed = true)
            is Input.SystemRemovalFailed -> removalCompleted(input.attempt, removed = false)
            is Input.PermitReleased -> on(input.attempt) { record ->
                if (record.releasingPermit == PermitRelease(input.attempt, input.permit)) {
                    put(record.copy(releasingPermit = null))
                }
            }
            is Input.FrameworkReset -> records.values.filter { it.live && it.call.lifecycle !is Lifecycle.Previewing }.forEach {
                val error = CallError.SystemFailed(input.failure)
                val retained = it.retainedEnd?.takeIf { event -> withinRetention(event.at) }?.end
                if (retained != null) remoteFinish(it, retained.reason)
                else {
                    trace(Rule.RESET)
                    finish(it, EndReason.Failed(error), error)
                }
            }
            Input.AdapterIdle -> Unit
        }
        prune()
        // Admit a buffered end before the invitation consumes a slot in the event history.
        return Transition(
            State(policy, records, events.tail(), releasedPermits, actionIDs, generation, completed),
            effects.toList(), receipt, terminalCompletions.toList(), admission, removal,
        )
    }

    private fun incoming(input: Input.Incoming): CommandReceipt.Incoming {
        fun resolved(result: IncomingResult) = CommandReceipt.Incoming.Resolved(result)
        val seen = events[input.eventID]
        seen?.incoming?.let { return resolved(IncomingResult.Duplicate(it)) }
        val original = records.values.firstOrNull { it.invitationEvent == input.eventID }
        original?.admission?.let { return CommandReceipt.Incoming.Pending(it, duplicate = true) }
        if (!remember(input.eventID)) return resolved(IncomingResult.Refused(IncomingRefusal.EventAlreadyUsed))

        val existing = records[input.callID]
        val remaining = input.expiresAt?.minus(clocks.utc)
        val refusal = when {
            existing != null -> IncomingRefusal.CallAlreadyExists(existing.call.lifecycle.kind)
            remaining != null && remaining <= Duration.ZERO -> IncomingRefusal.Expired
            else -> null
        }
        if (refusal != null) {
            val decision = IncomingResult.Refused(refusal)
            rememberAdmission(input.eventID, decision)
            return resolved(decision)
        }
        trace(Rule.INCOMING)
        val attempt = attempt(input.callID)
        val record = Record(
            createCall(input.callID, input.line, listOf(input.party), Direction.INCOMING, Lifecycle.Reporting),
            admission = attempt, invitationEvent = input.eventID, invitationDeadline = remaining?.let { now + it },
        )
        put(record)
        drain(input.callID, EndTarget.Canonical(input.callID))
        effects += Effect.ReportIncoming(attempt)
        return CommandReceipt.Incoming.Pending(attempt, duplicate = false)
    }

    private fun rememberAdmission(eventID: EventID, decision: IncomingResult.Decision) {
        // The initial entry may have expired while the native operation was pending.
        val entry = events[eventID] ?: SeenEvent(now, ++generation)
        events = events + (eventID to entry.copy(incoming = decision))
    }

    private fun resolveAdmission(record: Record, decision: IncomingResult.Decision): Record {
        val attempt = requireNotNull(record.admission)
        rememberAdmission(requireNotNull(record.invitationEvent), decision)
        admission = AdmissionCompletion(attempt, decision)
        return record.copy(admission = null, invitationEvent = null)
    }

    private fun admitted(input: Input.Admitted) = on(input.attempt) { record ->
        if (record.admission != input.attempt) return@on
        if (record.call.lifecycle != Lifecycle.Reporting) {
            val refusal = when (val lifecycle = record.call.lifecycle) {
                is Lifecycle.Previewing -> IncomingRefusal.Previewed(lifecycle.reason)
                is Lifecycle.Ended -> IncomingRefusal.Ended(lifecycle.reason)
                is Lifecycle.Ending -> IncomingRefusal.Ended(lifecycle.reason)
                else -> IncomingRefusal.CallAlreadyExists(lifecycle.kind)
            }
            val admitted = resolveAdmission(record, IncomingResult.Refused(refusal))
            if (!record.live) trace(Rule.LATE_ADMISSION)
            val reason = if (record.live) EndReason.AnsweredElsewhere else record.reason
            val current = !record.live || record.call.lifecycle is Lifecycle.Previewing
            put(requestRemoval(admitted, attempt(record.call.id), reason, current))
            return@on
        }
        val end = record.retainedEnd?.takeIf { withinRetention(it.at) }?.end?.reason
        if (end != null) {
            val previews = preview(end)
            val refusal = if (previews) IncomingRefusal.Previewed(PreviewReason.AnsweredElsewhere)
                else IncomingRefusal.Ended(end)
            val admitted = resolveAdmission(record, IncomingResult.Refused(refusal))
            trace(if (previews) Rule.ADMITTED_RETAINED_PREVIEW else Rule.ADMITTED_RETAINED_END)
            remoteFinish(admitted, end)
        } else if (record.invitationDeadline?.let { now >= it } == true) {
            trace(Rule.NO_ANSWER)
            val expired = resolveAdmission(record, IncomingResult.Refused(IncomingRefusal.Expired))
            finish(expired, EndReason.Unanswered)
        } else {
            trace(Rule.ADMITTED)
            val admitted = resolveAdmission(record, IncomingResult.Admitted)
            val deadline = minOf(now + budgets.incomingRing, admitted.invitationDeadline ?: Instant.DISTANT_FUTURE)
            val ringing = admitted.copy(call = admitted.call.copy(lifecycle = Lifecycle.Ringing))
            put(arm(ringing.copy(retainedEnd = null), TimerKind.NO_ANSWER, deadline), publish = true)
        }
    }

    private fun admissionFailed(input: Input.AdmissionFailed) {
        val record = records[input.attempt.callID]
        if (record == null || record.admission != input.attempt) {
            trace(Rule.STALE_SYSTEM_FAILURE)
            return
        }
        val retired = resolveAdmission(record, IncomingResult.Refused(IncomingRefusal.SystemFailed(input.failure)))
        if (record.call.lifecycle != Lifecycle.Reporting) {
            put(if (record.live) retired else retired.copy(removal = null, removalEvidence = RemovalEvidence.NOT_APPLICABLE))
            return
        }
        trace(Rule.ADMISSION_FAILED)
        val retained = record.retainedEnd?.takeIf { withinRetention(it.at) }?.end
        val reason = retained?.reason ?: EndReason.Failed(CallError.SystemFailed(input.failure))
        finish(retired.copy(removalEvidence = RemovalEvidence.NOT_APPLICABLE), reason, removeFromSystem = false)
    }

    private fun startAdmitted(input: Input.StartAdmitted) {
        val record = records[input.attempt.callID]
        val start = record?.nativeStart
        if (record == null || start?.attempt != input.attempt) {
            trace(Rule.STALE_SYSTEM_FAILURE)
            return
        }
        // An admission at the deadline still needs disconnecting if the call has expired.
        expireDue(record, TimerKind.NO_ANSWER)
        val current = records.getValue(record.call.id)
        val admitted = current.copy(nativeStart = null, outgoingProgress = emptyList())
        if (!current.live) {
            trace(Rule.LATE_START_ADMISSION)
            put(requestRemoval(admitted, attempt(record.call.id), current.reason))
            return
        }
        trace(if (current.outgoingProgress.isEmpty()) Rule.START_ADMITTED else Rule.APPLY_START_PROGRESS)
        put(admitted)
        effects += Effect.SettleAction(record.call.id, start.actionID)
        current.outgoingProgress.forEach { progress ->
            val updated = records.getValue(record.call.id)
            when (progress) {
                OutgoingProgress.CONNECTED -> connect(updated)
                OutgoingProgress.PROVIDE_MEDIA -> provideMedia(updated)
            }
        }
    }

    private fun startFailed(input: Input.StartFailed) {
        val record = records[input.attempt.callID]
        val placing = record?.call?.lifecycle == Lifecycle.Placing && record.call.direction == Direction.OUTGOING &&
            record.placement?.attempt == input.attempt
        if (record == null || (!placing && record.nativeStart?.attempt != input.attempt)) {
            trace(Rule.STALE_SYSTEM_FAILURE)
            return
        }
        if (!placing) expireDue(record, TimerKind.NO_ANSWER)
        val current = records.getValue(record.call.id)
        val retired = current.copy(nativeStart = null, removalEvidence = RemovalEvidence.NOT_APPLICABLE)
        if (!current.live) {
            trace(Rule.RETIRE_FAILED_START)
            put(retired)
            return
        }
        trace(Rule.START_FAILED)
        val error = CallError.SystemFailed(input.failure)
        current.nativeStart?.let { reject(current.call.id, it.actionID, error) }
        finish(retired, EndReason.Failed(error), error, removeFromSystem = false)
    }

    private fun request(input: Input.Request) {
        val action = input.action
        if (action is Action.Start) {
            start(Input.Start(action.callID, action.line, listOf(action.party), false, input.id, input.effectiveDeadline))
            return
        }
        val record = records[action.callID]
        if (action !is Action.End && !rememberAction(input.id)) return
        if (record == null) return reject(input, CallError.UnknownCall(action.callID))
        when (action) {
            is Action.Start -> reject(input, CallError.InvalidTransition(record.call.lifecycle.kind))
            is Action.Join -> {
                val preview = record.call.lifecycle as? Lifecycle.Previewing
                    ?: return reject(input, CallError.InvalidTransition(record.call.lifecycle.kind))
                if (!slotAvailable()) return reject(input, CallError.Refused(RefusalReason.NotAllowed))
                placement(
                    record.copy(previousPreview = preview.reason, removal = null, removalEvidence = RemovalEvidence.UNCONFIRMED),
                    input.id, input.effectiveDeadline, Rule.JOIN,
                )
            }
            is Action.Answer -> answer(record, input)
            is Action.End -> end(record, input.id)
            else -> control(record, input)
        }
    }

    private fun start(input: Input.Start) {
        if (!rememberAction(input.id)) return
        val existing = records[input.callID]
        if (existing != null) {
            return reject(input.callID, input.id, CallError.InvalidTransition(existing.call.lifecycle.kind))
        }
        if (!slotAvailable()) return reject(input.callID, input.id, CallError.Refused(RefusalReason.NotAllowed))
        val call = createCall(input.callID, input.line, input.parties, Direction.OUTGOING, Lifecycle.Placing, input.video)
        placement(Record(call), input.id, input.effectiveDeadline, Rule.START)
    }

    private fun placement(record: Record, id: ActionID, effectiveDeadline: Duration?, rule: Rule) {
        val attempt = attempt(record.call.id)
        val allowance = minOf(budgets.placement, effectiveDeadline ?: budgets.placement)
        if (allowance <= Duration.ZERO) return reject(record.call.id, id, CallError.DeadlineExceeded(TimedStage.PLACEMENT))
        trace(rule)
        val deadline = now + allowance
        val placing = record.copy(
            call = record.call.copy(lifecycle = Lifecycle.Placing), placement = Pending(attempt, id, deadline),
        )
        put(arm(placing, TimerKind.PLACEMENT, deadline))
        if (rule == Rule.START) drain(record.call.id, EndTarget.Canonical(record.call.id))
        if (records[record.call.id]?.placement?.attempt == attempt) effects += Effect.RequestPlacement(attempt, id, deadline)
    }

    private fun placed(input: Input.Placed): Boolean {
        val record = records[input.attempt.callID] ?: return false
        if (record.call.lifecycle != Lifecycle.Placing || record.placement?.attempt != input.attempt ||
            record.mediaAttempt != null || expireDue(record, TimerKind.PLACEMENT)
        ) return false
        when (val result = input.result) {
            is PlacementResult.Failed -> failPlacement(record, CallError.PlacementFailed(result.cause))
            is PlacementResult.Refused -> failPlacement(record, CallError.Refused(result.reason))
            is PlacementResult.Placed -> placeWithAlias(record, result.remoteID)
        }
        return true
    }

    private fun failPlacement(record: Record, error: CallError) {
        if (record.previousPreview != null) trace(Rule.JOIN_FAILED)
        val reason = when ((error as? CallError.Refused)?.reason) {
            RefusalReason.AnsweredElsewhere -> EndReason.AnsweredElsewhere
            RefusalReason.DeclinedElsewhere -> EndReason.DeclinedElsewhere
            else -> EndReason.Failed(error)
        }
        finish(record, reason, error, record.previousPreview)
    }

    private fun placeWithAlias(record: Record, remoteID: RemoteCallID?) {
        val callID = record.call.id
        if (remoteID != null) {
            val binding = bindAlias(record, remoteID)
            if (binding is Outcome.Failure) return failPlacement(record, binding.error)
        }
        // A buffered terminal event may cancel placement while the alias is being bound.
        val current = records.getValue(callID)
        val placement = current.placement ?: return
        if (current.previousPreview != null || policy.outgoingMedia == OutgoingMedia.DURING_PLACEMENT) {
            trace(if (current.previousPreview != null) Rule.PLACED_JOIN else Rule.PLACED_EAGER)
            prepare(current, placement.deadline)
        } else {
            trace(Rule.PLACED_OUTGOING)
            nativeStart(current)
        }
    }

    private fun nativeStart(record: Record) {
        val pending = requireNotNull(record.placement)
        val nativeStart = Effect.NativeStart(pending.attempt, pending.id)
        val dialing = cancel(record, TimerKind.PLACEMENT).copy(
            call = record.call.copy(lifecycle = Lifecycle.Dialing), placement = null, nativeStart = nativeStart,
        )
        put(arm(dialing, TimerKind.NO_ANSWER, now + budgets.outgoingNoAnswer))
        effects += nativeStart
        effects += Effect.Publish(dialing.call)
    }

    private fun answer(record: Record, input: Input.Request) {
        if (record.call.lifecycle != Lifecycle.Ringing || record.answer != null) {
            return reject(input, CallError.InvalidTransition(record.call.lifecycle.kind))
        }
        if (!slotAvailable()) return reject(input, CallError.Refused(RefusalReason.NotAllowed))
        val budget = budgets.answer
        val total = minOf(budget.total, input.effectiveDeadline ?: budget.total)
        if (total <= budget.claim + budget.reconciliation + budget.settlementReserve) {
            return reject(input, CallError.InvalidConfiguration(ConfigurationField.ANSWER_BUDGET))
        }
        trace(Rule.ANSWER)
        val attempt = attempt(record.call.id)
        val pending = Pending(attempt, input.id, now + total)
        val answering = cancel(record, TimerKind.NO_ANSWER).copy(answer = pending)
        val bounded = arm(answering, TimerKind.ANSWER, pending.deadline)
        put(arm(bounded, TimerKind.CLAIM, now + budget.claim))
        effects += Effect.RequestClaim(attempt, input.id)
    }

    private fun allowed(input: Input.AuthorityAllowed) {
        val key = PermitKey(input.attempt.callID, input.permit)
        if (key in releasedPermits) return
        records[input.attempt.callID]?.let { expireDue(it, TimerKind.CLAIM, TimerKind.RECONCILIATION, TimerKind.ANSWER) }
        val record = records[input.attempt.callID]
        if (record?.releasingPermit?.permit == input.permit) return
        val answer = record?.answer
        if (record == null || answer == null || (record.reconciliation ?: answer.attempt) != input.attempt ||
            record.permit != null || now >= answer.deadline - budgets.answer.settlementReserve
        ) {
            if (record?.permit != input.permit) {
                trace(Rule.STALE_PERMIT)
                releasePermit(input.permit, input.attempt)
            }
            return
        }
        trace(Rule.AUTHORITY_ALLOWED)
        val allowed = cancel(cancel(record, TimerKind.CLAIM), TimerKind.RECONCILIATION).copy(
            permit = input.permit, permitAttempt = input.attempt,
        )
        prepare(allowed, answer.deadline - budgets.answer.settlementReserve)
    }

    private fun answerRefused(input: Input.AnswerRefused) = on(input.attempt) { record ->
        val answer = record.answer ?: return@on
        if ((record.reconciliation ?: answer.attempt) != input.attempt || record.permit != null) return@on
        if (expireDue(record, TimerKind.CLAIM, TimerKind.RECONCILIATION, TimerKind.ANSWER)) return@on
        val error = CallError.Refused(input.reason)
        val reason = when (input.reason) {
            RefusalReason.AnsweredElsewhere -> EndReason.AnsweredElsewhere
            RefusalReason.DeclinedElsewhere -> EndReason.DeclinedElsewhere
            RefusalReason.NotAllowed -> EndReason.Failed(error)
        }
        if (preview(reason)) {
            trace(Rule.ANSWER_REFUSED_PREVIEW)
            finish(record, reason, error, PreviewReason.AnsweredElsewhere)
        } else {
            trace(if (input.reason == RefusalReason.NotAllowed) Rule.ANSWER_REFUSED_NOT_ALLOWED else Rule.ANSWER_REFUSED_ELSEWHERE)
            finish(record, reason, error)
        }
    }

    private fun prepare(record: Record, enclosing: Instant?) {
        val attempt = attempt(record.call.id)
        val preparing = record.copy(
            call = record.call.copy(media = record.call.media.copy(preparation = Preparation.PREPARING)),
            mediaAttempt = attempt,
        )
        val deadline = minOf(now + budgets.mediaPreparation, enclosing ?: Instant.DISTANT_FUTURE)
        put(arm(preparing, TimerKind.PREPARATION, deadline))
        effects += Effect.PrepareMedia(attempt)
    }

    private fun prepared(input: Input.MediaPrepared) = on(input.attempt) { record ->
        if (record.mediaAttempt != input.attempt || record.call.media.preparation != Preparation.PREPARING) return@on
        if (expireDue(record, TimerKind.PREPARATION, TimerKind.PLACEMENT, TimerKind.CONNECTION)) return@on
        val prepared = cancel(record, TimerKind.PREPARATION).copy(
            call = record.call.copy(media = record.call.media.copy(preparation = Preparation.PREPARED)),
        )
        val answer = prepared.answer
        val placement = prepared.placement
        when {
            prepared.call.lifecycle == Lifecycle.Ringing && answer != null && prepared.permit != null -> {
                trace(Rule.ANSWER_PREPARED)
                val ready = cancel(prepared, TimerKind.ANSWER).copy(answer = null, reconciliation = null)
                connecting(ready, answer)
            }
            prepared.call.lifecycle == Lifecycle.Placing && placement != null && prepared.previousPreview != null -> {
                trace(Rule.JOIN_PREPARED)
                connecting(cancel(prepared, TimerKind.PLACEMENT).copy(placement = null, joinAttempt = placement.attempt), placement)
            }
            prepared.call.lifecycle == Lifecycle.Placing && placement != null &&
                policy.outgoingMedia == OutgoingMedia.DURING_PLACEMENT -> {
                trace(Rule.EAGER_PREPARED)
                nativeStart(prepared)
            }
            prepared.call.lifecycle == Lifecycle.Connecting && prepared.bufferedConnection -> {
                trace(Rule.PREPARED_AFTER_REPORT)
                commitConnected(prepared)
            }
            else -> put(prepared)
        }
    }

    private fun connecting(record: Record, pending: Pending) {
        effects += Effect.SettleAction(record.call.id, pending.id, pending.deadline)
        val ready = record.copy(call = record.call.copy(lifecycle = Lifecycle.Connecting))
        if (ready.bufferedConnection) commitConnected(ready)
        else put(arm(ready, TimerKind.CONNECTION, now + budgets.connection), publish = true)
    }

    private fun connected(input: Input.Connected) {
        if (!remember(input.eventID) || input.source != policy.connectionAuthority) return
        records[input.callID]?.let(::connect)
    }

    private fun connect(record: Record) {
        if (record.call.lifecycle.kind !in setOf(LifecycleKind.DIALING, LifecycleKind.CONNECTING)) return
        if (expireDue(record, TimerKind.NO_ANSWER, TimerKind.CONNECTION)) return
        if (record.nativeStart != null) {
            bufferOutgoingProgress(record, OutgoingProgress.CONNECTED)
            return
        }
        if (record.call.media.preparation == Preparation.PREPARED) {
            trace(Rule.CONNECTED)
            commitConnected(record)
        } else if (!record.bufferedConnection) {
            trace(Rule.EARLY_CONNECTED)
            val connecting = cancel(record, TimerKind.NO_ANSWER).copy(
                call = record.call.copy(lifecycle = Lifecycle.Connecting), bufferedConnection = true,
            )
            val timed = if (TimerKind.CONNECTION in connecting.timers) connecting
                else arm(connecting, TimerKind.CONNECTION, now + budgets.connection)
            put(timed, publish = true)
        }
    }

    private fun provideMedia(record: Record) {
        if (record.call.lifecycle.kind !in setOf(LifecycleKind.DIALING, LifecycleKind.CONNECTING) ||
            record.mediaAttempt != null || expireDue(record, TimerKind.CONNECTION, TimerKind.NO_ANSWER)
        ) return
        if (record.nativeStart != null) {
            bufferOutgoingProgress(record, OutgoingProgress.PROVIDE_MEDIA)
        } else {
            trace(Rule.DEFERRED_MEDIA)
            prepare(record, record.placement?.deadline)
        }
    }

    private fun bufferOutgoingProgress(record: Record, progress: OutgoingProgress) {
        if (progress in record.outgoingProgress) return
        trace(Rule.BUFFER_START_PROGRESS)
        put(record.copy(outgoingProgress = record.outgoingProgress + progress))
    }

    private fun commitConnected(record: Record) {
        val at = record.connectedAt ?: clocks.utc
        val connected = cancel(cancel(record, TimerKind.NO_ANSWER), TimerKind.CONNECTION).copy(
            call = record.call.copy(
                lifecycle = Lifecycle.Connected(at), media = record.call.media.copy(transport = Transport.CONNECTED),
            ),
            connectedAt = at, bufferedConnection = false, previousPreview = null, joinAttempt = null,
        )
        effects += Effect.SetActive(requireNotNull(connected.mediaAttempt))
        put(connected, publish = true)
    }

    private fun bind(input: Input.BindRemote): Outcome<Unit, CallError> {
        val record = records[input.callID] ?: return Outcome.Failure(CallError.UnknownCall(input.callID))
        if (record.call.remoteID == input.remoteID) return Outcome.Success(Unit)
        val outcome = bindAlias(record, input.remoteID)
        if (outcome is Outcome.Success) effects += Effect.Publish(records.getValue(input.callID).call)
        return outcome
    }

    private fun bindAlias(record: Record, remoteID: RemoteCallID): Outcome<Unit, CallError> {
        if (record.call.remoteID == remoteID) return Outcome.Success(Unit)
        if (!record.live) return Outcome.Failure(CallError.InvalidTransition(record.call.lifecycle.kind))
        if (record.call.remoteID != null || records.values.any { it.live && it.call.remoteID == remoteID }) {
            return Outcome.Failure(CallError.RemoteIdentityConflict(remoteID))
        }
        trace(Rule.BIND)
        put(record.copy(call = record.call.copy(remoteID = remoteID)))
        drain(record.call.id, EndTarget.Alias(remoteID))
        return Outcome.Success(Unit)
    }

    private fun receive(event: RemoteEvent): Outcome<ReceiveDisposition, CallError> {
        if (event is RemoteEvent.VideoRequested) return Outcome.Failure(CallError.Unsupported(Feature.VIDEO))
        if (eventKnown(event.eventID)) return Outcome.Success(ReceiveDisposition.DUPLICATE)
        val record = when (val target = event.target) {
            is EndTarget.Canonical -> records[target.id]
            is EndTarget.Alias -> records.values.firstOrNull { it.live && it.call.remoteID == target.id }
        }
        val pending = when {
            record != null -> null
            event is RemoteEvent.PartiesChanged -> event.copy(parties = event.parties.toList())
            else -> event
        }
        remember(event.eventID, pending)
        if (record == null) {
            if (event is RemoteEvent.Ended) trace(Rule.BUFFER_UNKNOWN_END)
            return Outcome.Success(ReceiveDisposition.BUFFERED)
        }
        applyRemote(record, event, events.getValue(event.eventID))
        return Outcome.Success(ReceiveDisposition.APPLIED)
    }

    private fun drain(callID: CallID, target: EndTarget) {
        val matching = events.values.filter { it.pending?.target == target }
        for (seen in matching) {
            val event = requireNotNull(seen.pending)
            events = events + (event.eventID to seen.copy(pending = null))
            applyRemote(records.getValue(callID), event, seen)
        }
    }

    private fun applyRemote(record: Record, event: RemoteEvent, seen: SeenEvent) {
        if (!record.live) return
        when (event) {
            is RemoteEvent.Connected -> if (policy.connectionAuthority == ConnectionAuthority.APPLICATION) {
                when {
                    record.call.lifecycle == Lifecycle.Placing && record.previousPreview == null ->
                        bufferOutgoingProgress(record, OutgoingProgress.CONNECTED)
                    record.call.lifecycle == Lifecycle.Placing -> put(record.copy(bufferedConnection = true))
                    record.answer != null -> put(record.copy(bufferedConnection = true))
                    else -> connect(record)
                }
            }
            is RemoteEvent.Ended -> applyRemoteEnd(record, seen.copy(pending = event), event.reason)
            is RemoteEvent.PartiesChanged -> if (record.call.parties != event.parties) {
                put(record.copy(call = record.call.copy(
                    parties = Collections.unmodifiableList(event.parties.toList()),
                )), publish = true)
            }
            is RemoteEvent.VideoRequested -> error("Unsupported requests cannot reach a call")
        }
    }

    private fun applyRemoteEnd(record: Record, event: SeenEvent, reason: EndReason) {
        if (record.call.lifecycle == Lifecycle.Reporting) {
            val retained = retain(record, event)
            if (retained !== record) trace(Rule.RETAIN_REPORTING_END)
            put(retained)
        } else {
            trace(when {
                record.nativeStart != null -> Rule.END_BEFORE_START_ADMISSION
                record.call.lifecycle == Lifecycle.Ringing && preview(reason) -> Rule.ELSEWHERE_PREVIEW
                else -> Rule.REMOTE_END
            })
            remoteFinish(record, reason)
        }
    }

    private fun remoteFinish(record: Record, reason: EndReason) {
        val preview = PreviewReason.AnsweredElsewhere.takeIf {
            record.call.lifecycle.kind in setOf(LifecycleKind.REPORTING, LifecycleKind.RINGING) && preview(reason)
        }
        finish(record, reason, preview = preview)
    }

    private fun end(record: Record, id: ActionID) {
        val receipt = record.localEnd
        if (!record.live) {
            trace(if (receipt != null) Rule.REPEAT_LOCAL_END else Rule.ALREADY_ENDED)
            val result = if (receipt != null) EndResult.Ended(EndReceipt(record.call.id, receipt, record.reason))
                else EndResult.AlreadyEnded(record.reason)
            effects += Effect.CompleteEnd(record.call.id, id, result)
            return
        }
        val retained = record.retainedEnd?.takeIf { withinRetention(it.at) }?.end
        if (retained != null) {
            trace(Rule.RETAINED_END_LOCAL_END)
            effects += Effect.CompleteEnd(record.call.id, id, EndResult.AlreadyEnded(retained.reason))
            return
        }
        trace(if (record.nativeStart != null) Rule.END_BEFORE_START_ADMISSION else Rule.LOCAL_END)
        val reason = if (record.call.lifecycle == Lifecycle.Ringing) EndReason.LocalDeclined else EndReason.LocalEnded
        finish(record.copy(localEnd = id), reason)
        effects += Effect.CompleteEnd(record.call.id, id, EndResult.Ended(EndReceipt(record.call.id, id, reason)))
    }

    private fun control(record: Record, input: Input.Request) {
        val action = input.action
        val tones = action is Action.Tones
        val talkState = record.call.lifecycle.kind in setOf(LifecycleKind.CONNECTED, LifecycleKind.RECONNECTING)
        val feature = when (action) {
            is Action.Hold -> Feature.HOLD
            is Action.Video -> Feature.VIDEO
            is Action.Tones -> Feature.TONES
            else -> null
        }
        if (tones && (record.call.lifecycle !is Lifecycle.Connected || !input.supported)) {
            if (record.call.lifecycle is Lifecycle.Connected) trace(Rule.TONES_UNSUPPORTED)
            return reject(input, CallError.Unsupported(Feature.TONES))
        }
        if (!record.live || action is Action.Hold && !talkState) {
            return reject(input, CallError.InvalidTransition(record.call.lifecycle.kind))
        }
        if (feature != null && !input.supported) return reject(input, CallError.Unsupported(feature))
        if (action is Action.Hold && !action.held && record.call.held && !slotAvailable()) {
            return reject(input, CallError.Refused(RefusalReason.NotAllowed))
        }
        if (record.controls.any { it.action::class == action::class }) {
            return reject(input, CallError.InvalidTransition(record.call.lifecycle.kind))
        }
        trace(when (action) {
            is Action.Hold -> Rule.HOLD
            is Action.Mute -> Rule.MUTE
            is Action.Video -> Rule.VIDEO
            is Action.Tones -> Rule.TONES
            else -> error("Expected a control action")
        })
        val attempt = attempt(record.call.id)
        put(record.copy(controls = record.controls + Control(action, attempt, input.id)))
        effects += if (action is Action.Tones) Effect.SendTones(attempt, action)
            else Effect.Apply(attempt, input.id, action)
    }

    private fun controlResult(attempt: Attempt, error: CallError?) = on(attempt) { record ->
        val pending = record.controls.firstOrNull { it.attempt == attempt } ?: return@on
        val updated = record.copy(controls = record.controls - pending)
        if (error != null) {
            trace(when (pending.action) {
                is Action.Hold -> Rule.HOLD_FAILED
                is Action.Mute -> Rule.MUTE_FAILED
                is Action.Video -> Rule.VIDEO_FAILED
                is Action.Tones -> Rule.TONES_FAILED
                else -> error("Expected a control action")
            })
            reject(record.call.id, pending.id, error)
            put(updated)
            return@on
        }
        val call = record.call
        val confirmed = when (val action = pending.action) {
            is Action.Hold -> {
                trace(Rule.HOLD_APPLIED)
                call.copy(held = action.held)
            }
            is Action.Mute -> {
                trace(Rule.MUTE_APPLIED)
                call.copy(muted = action.muted)
            }
            is Action.Video -> {
                trace(Rule.VIDEO_APPLIED)
                call.copy(video = action.enabled)
            }
            is Action.Tones -> {
                trace(Rule.TONES_APPLIED)
                call
            }
            else -> error("Expected a control action")
        }
        val tones = pending.action as? Action.Tones
        put(updated.copy(call = confirmed), publish = tones == null)
        if (tones != null) effects += Effect.TonesPerformed(call.id, pending.id, tones.digits)
        effects += Effect.SettleAction(call.id, pending.id)
    }

    private fun expired(input: Input.TimerExpired) = on(input.attempt) { record ->
        val timer = record.timers[input.kind] ?: return@on
        if (timer.attempt != input.attempt || now < timer.deadline) return@on
        val fired = record.copy(timers = record.timers - input.kind)
        when (input.kind) {
            TimerKind.NO_ANSWER -> if (record.answer == null && !record.bufferedConnection &&
                record.call.lifecycle.kind in setOf(LifecycleKind.RINGING, LifecycleKind.DIALING)
            ) {
                trace(if (record.nativeStart == null) Rule.NO_ANSWER else Rule.START_ADMISSION_EXPIRED)
                finish(fired, EndReason.Unanswered)
            }
            TimerKind.CLAIM -> {
                val pending = record.answer ?: return@on
                if (record.reconciliation == null && record.permit == null) {
                    trace(Rule.CLAIM_EXPIRED)
                    val error = CallError.ClaimTimedOut(pending.id)
                    effects += Effect.ClaimTimedOut(pending.attempt, error)
                    val deadline = minOf(timer.deadline + budgets.answer.reconciliation, pending.deadline - budgets.answer.settlementReserve)
                    if (now >= deadline) {
                        trace(Rule.CLAIM_UNRESOLVED)
                        failAttempt(fired, error)
                        return@on
                    }
                    val reconciliation = attempt(record.call.id)
                    put(arm(fired.copy(reconciliation = reconciliation), TimerKind.RECONCILIATION, deadline))
                    effects += Effect.Reconcile(reconciliation, pending.id)
                }
            }
            TimerKind.RECONCILIATION -> {
                val pending = record.answer ?: return@on
                trace(Rule.CLAIM_UNRESOLVED)
                failAttempt(fired, CallError.ClaimTimedOut(pending.id))
            }
            TimerKind.ANSWER -> deadline(fired, CallError.DeadlineExceeded(TimedStage.SYSTEM_ACTION))
            TimerKind.PREPARATION -> deadline(fired, CallError.MediaFailed(MediaStage.PREPARE, MediaFailure.TIMEOUT))
            TimerKind.PLACEMENT -> deadline(fired, CallError.DeadlineExceeded(TimedStage.PLACEMENT))
            TimerKind.CONNECTION -> deadline(fired, CallError.DeadlineExceeded(TimedStage.CONNECTION))
            TimerKind.RECONNECTION -> deadline(fired, CallError.DeadlineExceeded(TimedStage.RECONNECTION))
        }
    }

    private fun deadline(record: Record, error: CallError) {
        trace(if (record.previousPreview != null) Rule.JOIN_DEADLINE else Rule.DEADLINE)
        failAttempt(record, error)
    }

    private fun failAttempt(record: Record, error: CallError) =
        finish(record, EndReason.Failed(error), error, record.previousPreview)

    private fun finish(
        record: Record,
        reason: EndReason,
        error: CallError? = null,
        preview: PreviewReason? = null,
        removeFromSystem: Boolean = true,
    ) {
        val attempt = attempt(record.call.id)
        val rejection = error ?: CallError.InvalidTransition(LifecycleKind.ENDING)
        listOfNotNull(record.answer?.id, record.placement?.id, record.nativeStart?.actionID).forEach {
            reject(record.call.id, it, rejection)
        }
        record.controls.forEach { reject(record.call.id, it.id, CallError.InvalidTransition(record.call.lifecycle.kind)) }
        val cancelled = record.timers.keys.fold(record, ::cancel)
        effects += Effect.CloseMedia(attempt, record.mediaAttempt)
        val releasing = record.permit?.let { permit ->
            val owner = requireNotNull(record.permitAttempt)
            releasePermit(permit, owner)
            PermitRelease(owner, permit)
        } ?: record.releasingPermit
        val awaitingPlacement = record.call.direction == Direction.OUTGOING && record.call.lifecycle == Lifecycle.Placing
        val removing = when {
            awaitingPlacement -> cancelled.copy(removalEvidence = RemovalEvidence.NOT_APPLICABLE)
            removeFromSystem && record.nativeStart == null -> requestRemoval(cancelled, attempt, reason)
            else -> cancelled
        }
        val next = preview?.let { Lifecycle.Previewing(it) } ?: Lifecycle.Ending(reason)
        put(removing.copy(
            call = record.call.copy(lifecycle = next, media = record.call.media.copy(
                audio = Audio.INACTIVE, transport = Transport.DISCONNECTED,
                preparation = if (preview != null) Preparation.RELEASED else record.call.media.preparation,
            )),
            answer = null, placement = null, outgoingProgress = emptyList(), permit = null,
            permitAttempt = null, mediaAttempt = null, controls = emptyList(),
            cleanup = attempt, mediaReleases = record.mediaReleases + attempt, releasingPermit = releasing,
            retainedEnd = null, reconciliation = null, bufferedConnection = false,
            previousPreview = null, joinAttempt = null, terminalAt = if (preview == null) now else null,
        ), publish = true)
    }

    private fun requestRemoval(record: Record, attempt: Attempt, reason: EndReason, current: Boolean = true): Record {
        effects += Effect.RequestRemoval(attempt, reason)
        val pending = record.copy(removals = record.removals + attempt)
        return if (current) pending.copy(removal = attempt, removalEvidence = RemovalEvidence.UNCONFIRMED) else pending
    }

    private fun removalCompleted(attempt: Attempt, removed: Boolean) = on(attempt) { record ->
        if (attempt !in record.removals) return@on
        removal = RemovalCompletion(attempt, removed)
        val updated = record.copy(removals = record.removals - attempt)
        if (attempt != record.removal) {
            put(updated)
            return@on
        }
        val publish = removed && !record.live
        if (publish) trace(Rule.REMOVED)
        val evidence = if (removed) RemovalEvidence.REMOVED else RemovalEvidence.UNCONFIRMED
        put(updated.copy(removal = null, removalEvidence = evidence), publish = publish)
    }

    private fun mediaReleased(attempt: Attempt) = on(attempt) { record ->
        if (attempt !in record.mediaReleases) return@on
        val updated = record.copy(mediaReleases = record.mediaReleases - attempt)
        val ending = record.call.lifecycle as? Lifecycle.Ending
        if (ending == null || updated.mediaReleases.isNotEmpty()) {
            put(updated)
            return@on
        }
        trace(Rule.MEDIA_RELEASED)
        put(updated.copy(call = record.call.copy(
            lifecycle = Lifecycle.Ended(ending.reason, clocks.utc),
            media = record.call.media.copy(preparation = Preparation.RELEASED),
        )), publish = true)
    }

    private fun put(record: Record, publish: Boolean = false) {
        records = records + (record.call.id to record)
        if (publish) effects += Effect.Publish(record.call)
    }

    private fun arm(record: Record, kind: TimerKind, deadline: Instant): Record {
        val attempt = attempt(record.call.id)
        effects += Effect.ArmTimer(attempt, kind, deadline)
        return record.copy(timers = record.timers + (kind to Armed(attempt, deadline)))
    }

    private fun cancel(record: Record, kind: TimerKind): Record {
        record.timers[kind]?.let { effects += Effect.CancelTimer(it.attempt, kind) }
        return record.copy(timers = record.timers - kind)
    }

    private fun expireDue(record: Record, vararg kinds: TimerKind): Boolean {
        val due = kinds.mapNotNull { kind -> record.timers[kind]?.let { kind to it } }
            .filter { (_, timer) -> now >= timer.deadline }
            .minByOrNull { (_, timer) -> timer.deadline } ?: return false
        expired(Input.TimerExpired(due.second.attempt, due.first))
        return true
    }

    private fun releasePermit(permit: AttemptID, attempt: Attempt) {
        val key = PermitKey(attempt.callID, permit)
        if (key in releasedPermits) return
        releasedPermits = (releasedPermits + (key to now)).tail()
        effects += Effect.ReleasePermit(permit, attempt)
    }

    private fun retain(record: Record, event: SeenEvent): Record {
        val retained = record.retainedEnd
        return if (retained == null || !withinRetention(retained.at) || event.order < retained.order) {
            record.copy(retainedEnd = event)
        } else record
    }

    private fun remember(id: EventID, pending: RemoteEvent? = null): Boolean {
        if (eventKnown(id)) return false
        events = events + (id to SeenEvent(now, ++generation, pending))
        return true
    }

    private fun eventKnown(id: EventID): Boolean =
        id in events || records.values.any { it.admission != null && it.invitationEvent == id }

    private fun rememberAction(id: ActionID): Boolean {
        if (id in actionIDs || records.values.any { it.pending(id) }) return false
        actionIDs = (actionIDs + (id to now)).tail()
        return true
    }

    private fun prune() {
        val eligible = records.values.filter { it.canPrune && it.call.id !in pendingAdapterWork }
        val newlyCompleted = eligible.map { it.call.id } - completed
        terminalCompletions.addAll(newlyCompleted)
        val retained = eligible
            .filter { withinRetention(requireNotNull(it.terminalAt)) }
            .sortedWith(terminalOrder)
            .takeLast(retention.terminalRecords).map { it.call.id }.toSet()
        val expired = eligible.map { it.call.id }.toSet() - retained
        records = records - expired
        completed = (completed + newlyCompleted) - expired
    }

    private fun attempt(id: CallID): Attempt = Attempt(id, ++generation)
    private fun withinRetention(at: Instant): Boolean = now - at < retention.lifetime
    private fun <K, V> Map<K, V>.tail(): Map<K, V> =
        entries.toList().takeLast(retention.terminalRecords).associate { it.key to it.value }
    private fun slotAvailable(): Boolean = records.values.count { record ->
        record.participating || record.controls.any { (it.action as? Action.Hold)?.held == false }
    } < policy.maximumParticipatingCalls
    private fun preview(reason: EndReason): Boolean = policy.previewAnsweredElsewhere && reason == EndReason.AnsweredElsewhere
    private fun reject(input: Input.Request, error: CallError) = reject(input.action.callID, input.id, error)
    private fun reject(id: CallID, actionID: ActionID?, error: CallError) { effects += Effect.RejectAction(id, actionID, error) }
    private inline fun on(attempt: Attempt, apply: (Record) -> Unit) {
        val record = records[attempt.callID] ?: return
        apply(record)
        // An ended call still accepts owned admission and cleanup results.
        if (record.call.lifecycle is Lifecycle.Ended && records[attempt.callID] === record) trace(Rule.LATE)
    }

    private fun createCall(
        id: CallID, line: CallingLine, parties: List<Party>, direction: Direction, lifecycle: Lifecycle, video: Boolean = false,
    ): Call =
        Call(id, line, direction, Collections.unmodifiableList(parties.toList()), lifecycle, held = false, muted = false, video = video,
            Media(Owner.NATIVE, Preparation.UNPROVIDED, Audio.INACTIVE, Transport.DISCONNECTED))
}

private val Record.live: Boolean get() = terminalAt == null
private val Record.canPrune: Boolean get() =
    call.lifecycle is Lifecycle.Ended && call.media.preparation == Preparation.RELEASED &&
        mediaReleases.isEmpty() && removals.isEmpty() && releasingPermit == null &&
        admission == null && placement == null && nativeStart == null && joinAttempt == null && answer == null &&
        reconciliation == null && permit == null && mediaAttempt == null && controls.isEmpty() && timers.isEmpty()
private fun Record.pending(id: ActionID): Boolean =
    answer?.id == id || placement?.id == id || (live && nativeStart?.actionID == id) || controls.any { it.id == id }
private val Record.reason: EndReason get() = when (val lifecycle = call.lifecycle) {
    is Lifecycle.Ending -> lifecycle.reason
    is Lifecycle.Ended -> lifecycle.reason
    else -> error("No terminal reason")
}
