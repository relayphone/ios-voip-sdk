package com.relayphone.voip.testing

import com.relayphone.voip.*
import kotlin.time.Duration
import kotlin.time.Instant
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertEquals

/** Drives the real reducer. Ports see effects and controls only, never expectations. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class JourneyDriver(private val scope: TestScope, private val configuration: Configuration) {
    private var state = State(configuration)
    private val timerJobs = mutableMapOf<Attempt, Job>()
    private val inbox = ArrayDeque<Input>()
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
    private val now: Instant get() = Instant.fromEpochMilliseconds(scope.testScheduler.currentTime)

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
            is Control.Admitted -> send(Input.Admitted(system.admissions.remove(control.callID) ?: error("Missing admission")))
            is Control.HoldApplied -> send(Input.Applied(system.controls.remove(control.callID) ?: error("Missing hold request")))
            is Control.Placed -> send(Input.Placed(system.placements.remove(control.callID) ?: error("Missing placement")))
            is Control.LatePermit -> {
                val attempt = authority.claims.getValue(control.callID)
                send(Input.AuthorityAllowed(attempt, AttemptID("late-${attempt.generation}")))
            }
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

    fun close() {
        timerJobs.values.forEach(Job::cancel)
        timerJobs.clear()
    }

    private fun send(input: Input) {
        inbox.addLast(input)
        while (inbox.isNotEmpty()) {
            val transition = reduce(state, inbox.removeFirst(), now)
            state = transition.state
            transition.effects.forEach(::perform)
        }
    }

    private fun perform(effect: Effect) {
        when (effect) {
            is Effect.ArmTimer -> {
                timerJobs[effect.attempt] = scope.backgroundScope.launch {
                    delay((effect.deadline - now).coerceAtLeast(Duration.ZERO))
                    timerJobs.remove(effect.attempt)
                    send(Input.TimerExpired(effect.attempt, effect.kind))
                }
            }
            is Effect.CancelTimer -> timerJobs.remove(effect.attempt)?.cancel()
            is Effect.ReportIncoming -> system.report(effect.attempt)
            is Effect.RequestPlacement -> {
                increment(effect.attempt.callID, Metric.PLACEMENTS)
                system.placements[effect.attempt.callID] = effect.attempt
            }
            is Effect.NativeStart -> {
                system.nativeCalls += effect.attempt.callID
                settle(effect.attempt.callID, effect.actionID)
            }
            is Effect.RequestClaim -> authority.claim(effect)
            is Effect.Reconcile -> authority.reconcile(effect)
            is Effect.ClaimTimedOut -> increment(effect.attempt.callID, Metric.CLAIM_TIMEOUTS)
            is Effect.ReleasePermit -> {
                increment(effect.attempt.callID, Metric.PERMIT_RELEASES)
                inbox += Input.PermitReleased(effect.attempt, effect.permit)
            }
            is Effect.PrepareMedia -> media.prepare(effect.attempt)
            is Effect.CloseMedia -> media.close(effect.attempt, effect.mediaAttempt)
            is Effect.RequestRemoval -> system.remove(effect)
            is Effect.SetActive -> {
                check(effect.attempt.callID in system.nativeCalls)
                increment(effect.attempt.callID, Metric.ACTIVATIONS)
                media.activate(effect.attempt)
            }
            is Effect.Apply -> system.apply(effect)
            is Effect.SendTones -> media.sendTones(effect.attempt)
            is Effect.TonesPerformed -> Unit
            is Effect.Publish -> if (effect.call.lifecycle == Lifecycle.Ringing) increment(effect.call.id, Metric.RINGING_PUBLICATIONS)
            is Effect.SettleAction -> settle(effect.callID, effect.actionID)
            is Effect.RejectAction -> {
                errors[effect.callID] = effect.error
                effect.actionID?.let { settle(effect.callID, it) }
            }
            is Effect.CompleteEnd -> {
                val result = effect.result
                ends[effect.callID] = result
                if (result is EndResult.Ended && endReceipts.add(result.receipt)) {
                    increment(effect.callID, Metric.PERFORMED_ENDS)
                }
            }
        }
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

    private inner class FakeSystem {
        val admissions = mutableMapOf<CallID, Attempt>()
        val placements = mutableMapOf<CallID, Attempt>()
        val controls = mutableMapOf<CallID, Attempt>()
        val deferAdmission = mutableSetOf<CallID>()
        val deferControl = mutableSetOf<ActionID>()
        val nativeCalls = mutableSetOf<CallID>()
        val endCauses = mutableMapOf<CallID, SystemEndCause>()

        fun report(attempt: Attempt) {
            val id = attempt.callID
            increment(id, Metric.REPORTS)
            nativeCalls += id
            if (deferAdmission.remove(id)) admissions[id] = attempt
            else inbox += Input.Admitted(attempt)
        }

        fun apply(effect: Effect.Apply) {
            if (effect.action is Action.Hold) increment(effect.attempt.callID, Metric.HOLD_REQUESTS)
            if (deferControl.remove(effect.actionID)) {
                controls[effect.attempt.callID] = effect.attempt
            } else inbox += Input.Applied(effect.attempt)
        }

        fun remove(effect: Effect.RequestRemoval) {
            val id = effect.attempt.callID
            val call = state.calls.getValue(id)
            if (nativeCalls.remove(id)) endCauses[id] = when (effect.reason) {
                EndReason.LocalDeclined -> SystemEndCause.REJECTED
                EndReason.LocalEnded -> SystemEndCause.LOCAL
                EndReason.Unanswered -> if (call.direction == Direction.INCOMING) SystemEndCause.MISSED else SystemEndCause.REMOTE
                is EndReason.Failed -> if ((effect.reason as EndReason.Failed).error is CallError.Refused) SystemEndCause.REJECTED else SystemEndCause.REMOTE
                else -> SystemEndCause.REMOTE
            }
            inbox += Input.SystemRemoved(effect.attempt)
        }
    }

    private inner class FakeAuthority {
        val plans = mutableMapOf<CallID, Control.Authority>()
        val claims = mutableMapOf<CallID, Attempt>()
        private val actions = mutableMapOf<CallID, ActionID>()

        fun claim(effect: Effect.RequestClaim) {
            val id = effect.attempt.callID
            increment(id, Metric.CLAIMS)
            claims[id] = effect.attempt
            actions[id] = effect.actionID
            respond(effect.attempt, plans.getValue(id).claim)
        }

        fun reconcile(effect: Effect.Reconcile) {
            val id = effect.attempt.callID
            check(actions.getValue(id) == effect.actionID)
            increment(id, Metric.RECONCILIATIONS)
            respond(effect.attempt, plans.getValue(id).reconciliation)
        }

        private fun respond(attempt: Attempt, decision: Decision) {
            when (decision) {
                Decision.Allow -> inbox += Input.AuthorityAllowed(attempt, AttemptID("permit-${attempt.generation}"))
                is Decision.Refuse -> inbox += Input.AnswerRefused(attempt, decision.reason)
                Decision.Timeout, Decision.Unknown -> Unit // The corresponding engine deadline supplies the result.
            }
        }
    }

    private inner class FakeMedia {
        val available = mutableSetOf<CallID>()
        private val prepared = mutableMapOf<CallID, Attempt>()

        fun prepare(attempt: Attempt) {
            check(attempt.callID in available) { "Media preparation started before media was supplied" }
            check(prepared.put(attempt.callID, attempt) == null)
            inbox += Input.MediaPrepared(attempt)
        }

        fun activate(attempt: Attempt) {
            check(prepared[attempt.callID] == attempt)
            increment(attempt.callID, Metric.PUBLICATIONS)
        }

        fun sendTones(attempt: Attempt) {
            check(attempt.callID in prepared)
            inbox += Input.Applied(attempt)
        }

        fun close(attempt: Attempt, mediaAttempt: Attempt?) {
            if (mediaAttempt != null && prepared.remove(attempt.callID, mediaAttempt)) {
                increment(attempt.callID, Metric.RELEASES)
            }
            inbox += Input.MediaReleased(attempt)
        }
    }
}
