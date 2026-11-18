package com.relayphone.voip.testing

import com.relayphone.voip.*
import com.relayphone.voip.runtime.AnswerDecision
import com.relayphone.voip.runtime.AuthorityPort
import com.relayphone.voip.runtime.CallRuntime
import com.relayphone.voip.runtime.MediaPort
import com.relayphone.voip.runtime.MonotonicClock
import com.relayphone.voip.runtime.PresentationPort
import com.relayphone.voip.runtime.Reconciliation
import com.relayphone.voip.runtime.RuntimeEvent
import com.relayphone.voip.runtime.SystemPort
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertEquals

/** Drives the runtime with fake ports under virtual time. Fakes never read expectations. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class JourneyDriver(private val scope: TestScope, private val configuration: Configuration) {
    private val counters = mutableMapOf<CallID, MutableMap<Metric, Int>>()
    private val errors = mutableMapOf<CallID, CallError>()
    private val ends = mutableMapOf<CallID, EndResult>()
    private val endReceipts = mutableSetOf<EndReceipt>()
    private val settled = mutableSetOf<ActionID>()
    private val system = FakeSystem()
    private val authority = FakeAuthority()
    private val media = FakeMedia()
    private var sequence = 0
    private var running = false
    private var javascript = false
    private val runtime = when (val started = CallRuntime.start(
        configuration, scope.backgroundScope, system, authority, media,
        PresentationPort { call ->
            if (call.lifecycle == Lifecycle.Ringing) increment(call.id, Metric.RINGING_PUBLICATIONS)
        },
        monotonicClock = MonotonicClock { Instant.fromEpochMilliseconds(scope.testScheduler.currentTime) },
        utcClock = object : Clock {
            override fun now(): Instant = Instant.fromEpochMilliseconds(scope.testScheduler.currentTime)
        },
    )) {
        is Outcome.Success -> started.value
        is Outcome.Failure -> error("Invalid runtime configuration: ${started.error}")
    }
    private val state: State get() = runtime.state.value
    private val observationJob = scope.backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
        runtime.events.collect { event ->
            if (event is RuntimeEvent.ClaimTimedOut) increment(event.effect.attempt.callID, Metric.CLAIM_TIMEOUTS)
        }
    }

    fun apply(control: Control) {
        when (control) {
            is Control.Process -> {
                check(state.calls.isEmpty())
                running = control.running
                javascript = control.javascriptAttached
            }
            is Control.Incoming -> {
                running = true // Native intake launches the process without a JavaScript attachment.
                if (control.deferAdmission) system.deferAdmission += control.callID
                send(Input.Incoming(control.callID, control.eventID, control.line, control.party))
            }
            is Control.Authority -> authority.plans[control.callID] = control
            is Control.Request -> {
                check(running)
                if (control.origin == Origin.APP) check(javascript)
                val id = ActionID("request-${++sequence}")
                if (control.deferConfirmation) system.deferControl += id
                send(Input.Request(control.action, id, supported = true))
            }
            is Control.Admitted -> system.admit(control.callID)
            is Control.AdmissionFailed -> system.rejectSetup(control.callID, control.failure)
            is Control.StartAdmitted -> system.admitStart(control.callID, control.stale)
            is Control.StartFailed -> system.rejectSetup(control.callID, control.failure)
            is Control.HoldApplied -> system.confirmHold(control.callID)
            is Control.Placed -> {
                if (control.deferStartAdmission) system.deferAdmission += control.callID
                authority.confirmPlacement(control.callID)
            }
            is Control.LatePermit -> authority.deliverLatePermit(control.callID)
            is Control.ProvideMedia -> {
                media.available += control.callID
                send(Input.ProvideMedia(control.callID))
            }
            is Control.BindRemote -> send(Input.BindRemote(control.callID, control.remoteID))
            is Control.Connected -> send(Input.Connected(control.callID, control.eventID, ConnectionAuthority.APPLICATION))
            is Control.RemoteEnd -> send(Input.RemoteEnd(control.target, control.eventID, control.reason))
            is Control.Advance -> scope.advanceTimeBy(control.milliseconds)
        }
        scope.runCurrent()
    }

    fun verify(expectation: Expectation) {
        when (expectation) {
            is Expectation.Snapshot -> {
                val call = state.calls.getValue(expectation.callID)
                assertEquals(expectation.lifecycle, project(call.lifecycle))
                expectation.lineID?.let { assertEquals(it, call.line.lineID) }
                expectation.remoteID?.let { assertEquals(it, call.remoteID) }
                expectation.held?.let { assertEquals(it, call.held) }
                expectation.muted?.let { assertEquals(it, call.muted) }
            }
            is Expectation.Count -> assertEquals(expectation.value, counters.getValue(expectation.callID).getValue(expectation.metric))
            is Expectation.Participating -> assertEquals(expectation.callIDs.toSet(), state.participating)
            is Expectation.SystemEnd -> assertEquals(expectation.cause, system.endCauses[expectation.callID])
            is Expectation.End -> assertEquals(expectation.result, ends[expectation.callID])
            is Expectation.Error -> {
                val error = errors.getValue(expectation.callID)
                assertEquals(expectation.error, Wire.json.encodeToJsonElement(CallError.serializer(), error).jsonObject.getValue("kind").toString().removeSurrounding("\""))
                expectation.reason?.let { assertEquals(it, (error as CallError.Refused).reason) }
            }
        }
    }

    suspend fun close() {
        runtime.close()
        observationJob.cancelAndJoin()
    }

    private fun send(input: Input) {
        check(runtime.submit(input)) { "Runtime is closed" }
    }

    private fun project(lifecycle: Lifecycle): JsonObject {
        val data = Wire.json.encodeToJsonElement(Lifecycle.serializer(), lifecycle).jsonObject.toMutableMap()
        data.remove("connectedAt")
        data.remove("endedAt")
        val reason = data["reason"]?.jsonObject
        val error = reason?.get("error")?.jsonObject
        if (error != null) data["reason"] = JsonObject(reason + ("error" to error.getValue("kind")))
        return JsonObject(data)
    }

    private fun increment(id: CallID, metric: Metric) {
        val counter = counters.getOrPut(id) { Metric.entries.associateWith { 0 }.toMutableMap() }
        counter[metric] = counter.getValue(metric) + 1
    }

    private fun settle(id: CallID, action: ActionID) {
        check(settled.add(action)) { "Action ${action.value} settled twice" }
        increment(id, Metric.SETTLEMENTS)
    }

    private inner class FakeSystem : SystemPort {
        override val answerDeadline = 5.seconds
        private val admissions = mutableMapOf<CallID, () -> Unit>()
        private val deferredStarts = mutableMapOf<CallID, Attempt>()
        private val controls = mutableMapOf<CallID, CompletableDeferred<Unit>>()
        private val sessions = mutableMapOf<CallID, CompletableDeferred<Outcome<Unit, SystemFailure>>>()
        val deferAdmission = mutableSetOf<CallID>()
        val deferControl = mutableSetOf<ActionID>()
        val endCauses = mutableMapOf<CallID, SystemEndCause>()

        fun admit(id: CallID) = (admissions.remove(id) ?: error("Missing admission"))()

        fun admitStart(id: CallID, stale: Boolean) {
            val attempt = deferredStarts.getValue(id)
            if (stale) send(Input.StartAdmitted(attempt.copy(generation = 0))) else admit(id)
        }

        fun rejectSetup(id: CallID, failure: SystemFailure) {
            check(admissions.remove(id) != null)
            check(sessions.getValue(id).complete(Outcome.Failure(failure)))
        }

        fun confirmHold(id: CallID) {
            check(controls.getValue(id).complete(Unit))
        }

        override suspend fun reportIncoming(
            call: Call, request: Effect.ReportIncoming, admitted: () -> Unit,
        ): Outcome<Unit, SystemFailure> {
            val id = call.id
            increment(id, Metric.REPORTS)
            return session(id) {
                if (deferAdmission.remove(id)) admissions[id] = admitted else admitted()
            }
        }

        override suspend fun startOutgoing(
            call: Call, request: Effect.NativeStart, admitted: () -> Unit,
        ): Outcome<Unit, SystemFailure> = session(call.id) {
            if (deferAdmission.remove(call.id)) {
                deferredStarts[call.id] = request.attempt
                admissions[call.id] = admitted
            } else {
                admitted()
            }
        }

        private suspend fun session(id: CallID, opened: () -> Unit): Outcome<Unit, SystemFailure> {
            val closing = CompletableDeferred<Outcome<Unit, SystemFailure>>()
            check(sessions.put(id, closing) == null)
            try {
                opened()
                return closing.await()
            } finally {
                sessions.remove(id, closing)
                admissions.remove(id)
                deferredStarts.remove(id)
            }
        }

        override suspend fun apply(request: Effect.Apply): Outcome<Unit, CallError> {
            val id = request.attempt.callID
            if (request.action is Action.Hold) increment(id, Metric.HOLD_REQUESTS)
            if (deferControl.remove(request.actionID)) {
                val confirmation = CompletableDeferred<Unit>()
                check(controls.put(id, confirmation) == null)
                try {
                    confirmation.await()
                } finally {
                    controls.remove(id, confirmation)
                }
            }
            return Outcome.Success(Unit)
        }

        override suspend fun remove(call: Call, request: Effect.RequestRemoval): Outcome<Unit, SystemFailure> {
            val id = call.id
            val session = sessions.remove(id) ?: return Outcome.Success(Unit)
            endCauses[id] = when (val reason = request.reason) {
                EndReason.LocalDeclined -> SystemEndCause.REJECTED
                EndReason.LocalEnded -> SystemEndCause.LOCAL
                EndReason.Unanswered -> if (call.direction == Direction.INCOMING) SystemEndCause.MISSED else SystemEndCause.REMOTE
                is EndReason.Failed -> if (reason.error is CallError.Refused) SystemEndCause.REJECTED else SystemEndCause.REMOTE
                else -> SystemEndCause.REMOTE
            }
            session.complete(Outcome.Success(Unit))
            return Outcome.Success(Unit)
        }

        override suspend fun setActive(request: Effect.SetActive) {
            check(request.attempt.callID in sessions)
            increment(request.attempt.callID, Metric.ACTIVATIONS)
            media.observeActive(request.attempt)
        }

        override fun settle(result: Effect.SettleAction) = settle(result.callID, result.actionID)

        override fun reject(result: Effect.RejectAction) {
            errors[result.callID] = result.error
            result.actionID?.let { settle(result.callID, it) }
        }

        override fun completeEnd(result: Effect.CompleteEnd) {
            val end = result.result
            ends[result.callID] = end
            if (end is EndResult.Ended && endReceipts.add(end.receipt)) {
                increment(result.callID, Metric.PERFORMED_ENDS)
            }
        }
    }

    private inner class FakeAuthority : AuthorityPort {
        val plans = mutableMapOf<CallID, Control.Authority>()
        private val placements = mutableMapOf<CallID, CompletableDeferred<Unit>>()
        private val claims = mutableMapOf<CallID, Attempt>()
        private val actions = mutableMapOf<CallID, ActionID>()

        fun confirmPlacement(id: CallID) {
            check(placements.getValue(id).complete(Unit))
        }

        fun deliverLatePermit(id: CallID) {
            val attempt = claims.getValue(id)
            send(Input.AuthorityAllowed(attempt, AttemptID("late-${attempt.generation}")))
        }

        override suspend fun place(call: Call, request: Effect.RequestPlacement): Outcome<Unit, CallError.PlacementFailed> {
            increment(call.id, Metric.PLACEMENTS)
            val placement = CompletableDeferred<Unit>()
            check(placements.put(call.id, placement) == null)
            try {
                placement.await()
                return Outcome.Success(Unit)
            } finally {
                placements.remove(call.id, placement)
            }
        }

        override suspend fun claim(request: Effect.RequestClaim): AnswerDecision {
            val id = request.attempt.callID
            increment(id, Metric.CLAIMS)
            claims[id] = request.attempt
            actions[id] = request.actionID
            return respond(request.attempt, plans.getValue(id).claim)
        }

        override suspend fun reconcile(request: Effect.Reconcile): Reconciliation {
            val id = request.attempt.callID
            check(actions.getValue(id) == request.actionID)
            increment(id, Metric.RECONCILIATIONS)
            return respond(request.attempt, plans.getValue(id).reconciliation)
        }

        override suspend fun release(request: Effect.ReleasePermit) {
            increment(request.attempt.callID, Metric.PERMIT_RELEASES)
        }

        private suspend fun respond(attempt: Attempt, decision: Decision): AnswerDecision = when (decision) {
            Decision.Allow -> AnswerDecision.Allow(AttemptID("permit-${attempt.generation}"))
            is Decision.Refuse -> AnswerDecision.Refuse(decision.reason)
            Decision.Timeout, Decision.Unknown -> awaitCancellation()
        }
    }

    private inner class FakeMedia : MediaPort {
        val available = mutableSetOf<CallID>()
        private val prepared = mutableMapOf<CallID, Attempt>()

        override suspend fun prepare(request: Effect.PrepareMedia): Outcome<Unit, CallError.MediaFailed> {
            val attempt = request.attempt
            check(attempt.callID in available) { "Media preparation started before media was supplied" }
            check(prepared.put(attempt.callID, attempt) == null)
            return Outcome.Success(Unit)
        }

        fun observeActive(attempt: Attempt) {
            check(prepared[attempt.callID] == attempt)
            increment(attempt.callID, Metric.PUBLICATIONS)
        }

        override suspend fun sendTones(request: Effect.SendTones): Outcome<Unit, CallError> {
            check(request.attempt.callID in prepared)
            return Outcome.Success(Unit)
        }

        override suspend fun close(request: Effect.CloseMedia) {
            val id = request.attempt.callID
            if (request.mediaAttempt != null && prepared.remove(id, request.mediaAttempt)) {
                increment(id, Metric.RELEASES)
            }
        }
    }
}
