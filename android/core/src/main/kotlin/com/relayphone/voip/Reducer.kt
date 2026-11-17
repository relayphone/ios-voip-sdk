package com.relayphone.voip

import kotlin.time.Duration
import kotlin.time.Instant

/** Applies one input at a supplied instant. The caller executes effects in their returned order. */
public fun reduce(state: State, input: Input, instant: Instant): Transition =
    Reduction(state, instant).run(input)

private class Reduction(state: State, private val now: Instant) {
    private val policy = state.configuration
    private val budgets = policy.budgets
    private val retention = budgets.retention
    private var records = state.records
    private var events = state.events.filterValues { withinRetention(it.at) }
    private var releasedPermits = state.releasedPermits.filterValues(::withinRetention)
    private var actionIDs = state.actionIDs.filterValues(::withinRetention)
    private var generation = state.generation
    private val effects = mutableListOf<Effect>()

    fun run(input: Input): Transition {
        prune()
        when (input) {
            is Input.Incoming -> incoming(input)
            is Input.Admitted -> admitted(input)
            is Input.Request -> request(input)
            is Input.Placed -> placed(input)
            is Input.AuthorityAllowed -> allowed(input)
            is Input.AnswerRefused -> answerRefused(input)
            is Input.ReconciliationUnknown -> on(input.attempt) { record ->
                val answer = record.answer ?: return@on
                if (record.reconciliation == input.attempt && record.permit == null) {
                    val error = CallError.ClaimTimedOut(answer.id)
                    finish(record, EndReason.Failed(error), error)
                }
            }
            is Input.ProvideMedia -> records[input.id]?.let { record ->
                if (record.call.lifecycle.kind in setOf(LifecycleKind.DIALING, LifecycleKind.CONNECTING) &&
                    record.mediaAttempt == null && !expireDue(record, TimerKind.CONNECTION, TimerKind.NO_ANSWER)
                ) prepare(record, record.placement?.deadline)
            }
            is Input.MediaPrepared -> prepared(input)
            is Input.MediaFailed -> on(input.attempt) { record ->
                if (record.live && record.mediaAttempt == input.attempt) failAttempt(record, input.error)
            }
            is Input.Connected -> connected(input)
            is Input.BindRemote -> bind(input)
            is Input.RemoteEnd -> remoteEnd(input)
            is Input.Applied -> controlResult(input.attempt, null)
            is Input.ApplyFailed -> controlResult(input.attempt, input.error)
            is Input.TimerExpired -> expired(input)
            is Input.TransportLost -> on(input.attempt) { record ->
                val connected = record.call.lifecycle as? Lifecycle.Connected ?: return@on
                if (record.mediaAttempt == input.attempt) {
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
                    val recovered = cancel(record, TimerKind.RECONNECTION)
                    put(recovered.copy(call = recovered.call.copy(
                        lifecycle = Lifecycle.Connected(recovering.connectedAt),
                        media = recovered.call.media.copy(transport = Transport.CONNECTED),
                    )), publish = true)
                }
            }
            is Input.MediaReleased -> on(input.attempt) { record ->
                val ending = record.call.lifecycle as? Lifecycle.Ending ?: return@on
                if (record.cleanup == input.attempt) {
                    put(record.copy(call = record.call.copy(
                        lifecycle = Lifecycle.Ended(ending.reason, now),
                        media = record.call.media.copy(preparation = Preparation.RELEASED),
                    )), publish = true)
                }
            }
            is Input.SystemRemoved -> on(input.attempt) { record ->
                if (record.cleanup == input.attempt && !record.systemRemoved) {
                    put(record.copy(systemRemoved = true), publish = !record.live)
                }
            }
            is Input.FrameworkReset -> records.values.filter { it.live && it.call.lifecycle !is Lifecycle.Previewing }.forEach {
                val error = CallError.SystemFailed(input.failure)
                val retained = it.retainedEnd?.takeIf { event -> withinRetention(event.at) }?.end
                if (retained != null) remoteFinish(it, retained.reason)
                else finish(it, EndReason.Failed(error), error)
            }
        }
        prune()
        // Admit a buffered end before the invitation consumes a slot in the event history.
        return Transition(State(policy, records, events.tail(), releasedPermits, actionIDs, generation), effects.toList())
    }

    private fun incoming(input: Input.Incoming) {
        if (!remember(input.eventID) || input.callID in records || input.expiresAt?.let { it <= now } == true) return
        val attempt = attempt(input.callID)
        val record = Record(
            createCall(input.callID, input.line, input.party, Direction.INCOMING, Lifecycle.Reporting),
            admission = attempt, invitationExpiry = input.expiresAt,
        )
        put(buffered(EndTarget.Canonical(input.callID)).fold(record, ::retain))
        effects += Effect.ReportIncoming(attempt)
    }

    private fun admitted(input: Input.Admitted) = on(input.attempt) { record ->
        if (record.admission != input.attempt) return@on
        if (!record.live) {
            record.cleanup?.let { effects += Effect.RequestRemoval(it, record.reason) }
            put(record.copy(admission = null))
            return@on
        }
        if (record.call.lifecycle != Lifecycle.Reporting) return@on
        val admitted = record.copy(admission = null)
        val end = admitted.retainedEnd?.takeIf { withinRetention(it.at) }?.end?.reason
        if (end != null) {
            remoteFinish(admitted, end)
        } else {
            val deadline = minOf(now + budgets.incomingRing, admitted.invitationExpiry ?: Instant.DISTANT_FUTURE)
            val ringing = admitted.copy(call = admitted.call.copy(lifecycle = Lifecycle.Ringing))
            put(arm(ringing.copy(retainedEnd = null), TimerKind.NO_ANSWER, deadline), publish = true)
        }
    }

    private fun request(input: Input.Request) {
        val action = input.action
        val record = records[action.callID]
        if (action !is Action.End) {
            if (input.id in actionIDs || records.values.any { it.pending(input.id) }) return
            actionIDs = (actionIDs + (input.id to now)).tail()
        }
        if (action is Action.Start && record == null) {
            if (!slotAvailable()) return reject(input, CallError.Refused(RefusalReason.NotAllowed))
            placement(Record(createCall(action.callID, action.line, action.party, Direction.OUTGOING, Lifecycle.Placing)), input)
            return
        }
        if (record == null) return reject(input, CallError.UnknownCall(action.callID))
        when (action) {
            is Action.Start -> reject(input, CallError.InvalidTransition(record.call.lifecycle.kind))
            is Action.Join -> {
                val preview = record.call.lifecycle as? Lifecycle.Previewing
                    ?: return reject(input, CallError.InvalidTransition(record.call.lifecycle.kind))
                if (!slotAvailable()) return reject(input, CallError.Refused(RefusalReason.NotAllowed))
                placement(record.copy(previousPreview = preview.reason, cleanup = null, systemRemoved = false), input)
            }
            is Action.Answer -> answer(record, input)
            is Action.End -> end(record, input.id)
            else -> control(record, input)
        }
    }

    private fun placement(record: Record, input: Input.Request) {
        val attempt = attempt(record.call.id)
        val allowance = minOf(budgets.placement, input.effectiveDeadline ?: budgets.placement)
        if (allowance <= Duration.ZERO) return reject(input, CallError.DeadlineExceeded(TimedStage.PLACEMENT))
        val deadline = now + allowance
        val placing = record.copy(
            call = record.call.copy(lifecycle = Lifecycle.Placing), placement = Pending(attempt, input.id, deadline),
        )
        put(arm(placing, TimerKind.PLACEMENT, deadline))
        effects += Effect.RequestPlacement(attempt, input.id)
    }

    private fun placed(input: Input.Placed) = on(input.attempt) { record ->
        val error = input.error
        if (record.call.lifecycle == Lifecycle.Connecting && error != null && record.joinAttempt == input.attempt) {
            if (!expireDue(record, TimerKind.CONNECTION)) failAttempt(record, error)
            return@on
        }
        if (record.call.lifecycle != Lifecycle.Placing || record.placement?.attempt != input.attempt ||
            (error == null && record.mediaAttempt != null) || expireDue(record, TimerKind.PLACEMENT)
        ) return@on
        when {
            error != null -> failAttempt(record, error)
            record.previousPreview != null || policy.outgoingMedia == OutgoingMedia.DURING_PLACEMENT ->
                prepare(record, record.placement.deadline)
            else -> nativeStart(record)
        }
    }

    private fun nativeStart(record: Record) {
        val pending = requireNotNull(record.placement)
        val dialing = cancel(record, TimerKind.PLACEMENT).copy(
            call = record.call.copy(lifecycle = Lifecycle.Dialing), placement = null,
        )
        put(arm(dialing, TimerKind.NO_ANSWER, now + budgets.outgoingNoAnswer))
        effects += Effect.NativeStart(pending.attempt, pending.id)
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
        val answer = record?.answer
        if (record == null || answer == null || (record.reconciliation ?: answer.attempt) != input.attempt ||
            record.permit != null || now >= answer.deadline - budgets.answer.settlementReserve
        ) {
            if (record?.permit != input.permit) releasePermit(input.permit, input.attempt)
            return
        }
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
        if (preview(reason)) finish(record, reason, error, PreviewReason.AnsweredElsewhere)
        else finish(record, reason, error)
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
                val ready = cancel(prepared, TimerKind.ANSWER).copy(answer = null, reconciliation = null)
                connecting(ready, answer)
            }
            prepared.call.lifecycle == Lifecycle.Placing && placement != null && prepared.previousPreview != null ->
                connecting(cancel(prepared, TimerKind.PLACEMENT).copy(placement = null, joinAttempt = placement.attempt), placement)
            prepared.call.lifecycle == Lifecycle.Placing && placement != null &&
                policy.outgoingMedia == OutgoingMedia.DURING_PLACEMENT -> nativeStart(prepared)
            prepared.call.lifecycle == Lifecycle.Connecting && prepared.bufferedConnection -> commitConnected(prepared)
            else -> put(prepared)
        }
    }

    private fun connecting(record: Record, pending: Pending) {
        effects += Effect.SettleAction(record.call.id, pending.id, pending.deadline)
        put(arm(record.copy(call = record.call.copy(lifecycle = Lifecycle.Connecting)),
            TimerKind.CONNECTION, now + budgets.connection), publish = true)
    }

    private fun connected(input: Input.Connected) {
        if (!remember(input.eventID) || input.source != policy.connectionAuthority) return
        val record = records[input.callID] ?: return
        if (record.call.lifecycle.kind !in setOf(LifecycleKind.DIALING, LifecycleKind.CONNECTING)) return
        if (expireDue(record, TimerKind.NO_ANSWER, TimerKind.CONNECTION)) return
        if (record.call.media.preparation == Preparation.PREPARED) {
            commitConnected(record)
        } else if (!record.bufferedConnection) {
            val connecting = cancel(record, TimerKind.NO_ANSWER).copy(
                call = record.call.copy(lifecycle = Lifecycle.Connecting), bufferedConnection = true,
            )
            val timed = if (TimerKind.CONNECTION in connecting.timers) connecting
                else arm(connecting, TimerKind.CONNECTION, now + budgets.connection)
            put(timed, publish = true)
        }
    }

    private fun commitConnected(record: Record) {
        val at = record.connectedAt ?: now
        val connected = cancel(cancel(record, TimerKind.NO_ANSWER), TimerKind.CONNECTION).copy(
            call = record.call.copy(
                lifecycle = Lifecycle.Connected(at), media = record.call.media.copy(transport = Transport.CONNECTED),
            ),
            connectedAt = at, bufferedConnection = false, previousPreview = null, joinAttempt = null,
        )
        effects += Effect.SetActive(requireNotNull(connected.mediaAttempt))
        put(connected, publish = true)
    }

    private fun bind(input: Input.BindRemote) {
        val record = records[input.callID]
        when {
            record == null -> reject(input.callID, null, CallError.UnknownCall(input.callID))
            !record.live -> reject(input.callID, null, CallError.InvalidTransition(record.call.lifecycle.kind))
            record.call.remoteID == input.remoteID -> Unit
            record.call.remoteID != null || records.values.any { it.live && it.call.remoteID == input.remoteID } ->
                reject(input.callID, null, CallError.RemoteIdentityConflict(input.remoteID))
            else -> {
                put(record.copy(call = record.call.copy(remoteID = input.remoteID)))
                buffered(EndTarget.Alias(input.remoteID)).forEach { event ->
                    applyRemote(records.getValue(input.callID), event)
                }
                effects += Effect.Publish(records.getValue(input.callID).call)
            }
        }
    }

    private fun remoteEnd(input: Input.RemoteEnd) {
        if (input.eventID in events) return
        val record = when (val target = input.target) {
            is EndTarget.Canonical -> records[target.id]
            is EndTarget.Alias -> records.values.firstOrNull { it.live && it.call.remoteID == target.id }
        }
        remember(input.eventID, input.takeUnless { record?.live == false })
        if (record == null || !record.live) return
        applyRemote(record, events.getValue(input.eventID))
        events = events + (input.eventID to events.getValue(input.eventID).copy(end = null))
    }

    private fun applyRemote(record: Record, event: SeenEvent) {
        if (!record.live) return
        if (record.call.lifecycle == Lifecycle.Reporting) {
            put(retain(record, event))
        } else remoteFinish(record, requireNotNull(event.end).reason)
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
            val result = if (receipt != null) EndResult.Ended(EndReceipt(record.call.id, receipt, record.reason))
                else EndResult.AlreadyEnded(record.reason)
            effects += Effect.CompleteEnd(record.call.id, id, result)
            return
        }
        val retained = record.retainedEnd?.takeIf { withinRetention(it.at) }?.end
        if (retained != null) {
            effects += Effect.CompleteEnd(record.call.id, id, EndResult.AlreadyEnded(retained.reason))
            return
        }
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
        val attempt = attempt(record.call.id)
        put(record.copy(controls = record.controls + Control(action, attempt, input.id)))
        effects += if (action is Action.Tones) Effect.SendTones(attempt, action)
            else Effect.Apply(attempt, input.id, action)
    }

    private fun controlResult(attempt: Attempt, error: CallError?) = on(attempt) { record ->
        val pending = record.controls.firstOrNull { it.attempt == attempt } ?: return@on
        val updated = record.copy(controls = record.controls - pending)
        if (error != null) {
            reject(record.call.id, pending.id, error)
            put(updated)
            return@on
        }
        val call = record.call
        val confirmed = when (val action = pending.action) {
            is Action.Hold -> call.copy(held = action.held)
            is Action.Mute -> call.copy(muted = action.muted)
            is Action.Video -> call.copy(video = action.enabled)
            else -> call
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
            ) finish(fired, EndReason.Unanswered)
            TimerKind.CLAIM -> {
                val pending = record.answer ?: return@on
                if (record.reconciliation == null && record.permit == null) {
                    val error = CallError.ClaimTimedOut(pending.id)
                    effects += Effect.ClaimTimedOut(pending.attempt, error)
                    val deadline = minOf(timer.deadline + budgets.answer.reconciliation, pending.deadline - budgets.answer.settlementReserve)
                    if (now >= deadline) {
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
                failAttempt(fired, CallError.ClaimTimedOut(pending.id))
            }
            TimerKind.ANSWER -> failAttempt(fired, CallError.DeadlineExceeded(TimedStage.SYSTEM_ACTION))
            TimerKind.PREPARATION -> failAttempt(fired, CallError.MediaFailed(MediaStage.PREPARE, MediaFailure.TIMEOUT))
            TimerKind.PLACEMENT -> failAttempt(fired, CallError.DeadlineExceeded(TimedStage.PLACEMENT))
            TimerKind.CONNECTION -> failAttempt(fired, CallError.DeadlineExceeded(TimedStage.CONNECTION))
            TimerKind.RECONNECTION -> failAttempt(fired, CallError.DeadlineExceeded(TimedStage.RECONNECTION))
        }
    }

    private fun failAttempt(record: Record, error: CallError) =
        finish(record, EndReason.Failed(error), error, record.previousPreview)

    private fun finish(record: Record, reason: EndReason, error: CallError? = null, preview: PreviewReason? = null) {
        val attempt = attempt(record.call.id)
        val rejection = error ?: CallError.InvalidTransition(LifecycleKind.ENDING)
        listOfNotNull(record.answer?.id, record.placement?.id).forEach {
            reject(record.call.id, it, rejection)
        }
        record.controls.forEach { reject(record.call.id, it.id, CallError.InvalidTransition(record.call.lifecycle.kind)) }
        val cancelled = record.timers.keys.fold(record, ::cancel)
        effects += Effect.CloseMedia(attempt, record.mediaAttempt)
        record.permit?.let { releasePermit(it, requireNotNull(record.permitAttempt)) }
        effects += Effect.RequestRemoval(attempt, reason)
        val next = preview?.let { Lifecycle.Previewing(it) } ?: Lifecycle.Ending(reason)
        put(cancelled.copy(
            call = record.call.copy(lifecycle = next, media = record.call.media.copy(
                audio = Audio.INACTIVE, transport = Transport.DISCONNECTED,
                preparation = if (preview != null) Preparation.RELEASED else record.call.media.preparation,
            )),
            answer = null, placement = null, permit = null, permitAttempt = null, mediaAttempt = null, controls = emptyList(),
            cleanup = attempt, retainedEnd = null, reconciliation = null, bufferedConnection = false,
            previousPreview = null, joinAttempt = null, terminalAt = if (preview == null) now else null,
        ), publish = true)
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

    private fun buffered(target: EndTarget): List<SeenEvent> {
        val matching = events.filterValues { it.end?.target == target }
        events = events.mapValues { (id, event) -> if (id in matching) event.copy(end = null) else event }
        return matching.values.toList()
    }

    private fun retain(record: Record, event: SeenEvent): Record {
        val retained = record.retainedEnd
        return if (retained == null || !withinRetention(retained.at) || event.order < retained.order) {
            record.copy(retainedEnd = event)
        } else record
    }

    private fun remember(id: EventID, end: Input.RemoteEnd? = null): Boolean {
        if (id in events) return false
        events = events + (id to SeenEvent(now, ++generation, end))
        return true
    }

    private fun prune() {
        val retained = records.values.filter { it.terminalAt != null }
            .filter { withinRetention(requireNotNull(it.terminalAt)) }
            .sortedWith(compareBy({ it.terminalAt }, { it.cleanup?.generation }))
            .takeLast(retention.terminalRecords).map { it.call.id }.toSet()
        records = records.filterValues { it.live || it.call.id in retained }
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
    private inline fun on(attempt: Attempt, apply: (Record) -> Unit) { records[attempt.callID]?.let(apply) }

    private fun createCall(id: CallID, line: CallingLine, party: Party, direction: Direction, lifecycle: Lifecycle): Call =
        Call(id, line, direction, listOf(party), lifecycle, held = false, muted = false, video = false,
            Media(Owner.NATIVE, Preparation.UNPROVIDED, Audio.INACTIVE, Transport.DISCONNECTED))
}

private val Record.live: Boolean get() = terminalAt == null
private fun Record.pending(id: ActionID): Boolean =
    answer?.id == id || placement?.id == id || controls.any { it.id == id }
private val Record.reason: EndReason get() = when (val lifecycle = call.lifecycle) {
    is Lifecycle.Ending -> lifecycle.reason
    is Lifecycle.Ended -> lifecycle.reason
    else -> error("No terminal reason")
}
