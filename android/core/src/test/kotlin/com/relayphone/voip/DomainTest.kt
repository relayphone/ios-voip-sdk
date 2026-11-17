package com.relayphone.voip

import kotlin.time.Instant
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class DomainTest {
    @Test
    fun `lifecycle kinds preserve all progress stages and associated facts`() {
        val connectedAt = Instant.parse("2026-11-17T12:00:00Z")
        val endedAt = Instant.parse("2026-11-17T12:00:10Z")
        val previewReason = PreviewReason.Filtered(FilterCause.UNKNOWN)
        val cases = listOf(
            Lifecycle.Reporting, Lifecycle.Ringing, Lifecycle.Placing, Lifecycle.Dialing, Lifecycle.Connecting,
            Lifecycle.Previewing(previewReason), Lifecycle.Connected(connectedAt), Lifecycle.Reconnecting(connectedAt),
            Lifecycle.Ending(EndReason.LocalEnded), Lifecycle.Ended(EndReason.LocalEnded, endedAt),
        )
        assertEquals(LifecycleKind.entries.toSet(), cases.map { it.kind }.toSet())
        assertEquals(connectedAt, Lifecycle.Connected(connectedAt).connectedAt)
        assertEquals(connectedAt, Lifecycle.Reconnecting(connectedAt).connectedAt)
        assertEquals(previewReason, Lifecycle.Previewing(previewReason).reason)
        assertEquals(endedAt, Lifecycle.Ended(EndReason.LocalEnded, endedAt).endedAt)
        assertNotEquals(PreviewReason.AnsweredElsewhere, PreviewReason.Policy)
    }

    @Test
    fun `terminal reasons retain causes and distinguish decline hangup and elsewhere`() {
        val error = CallError.ClaimTimedOut(ActionID("answer"))
        val reasons = listOf(
            EndReason.LocalDeclined, EndReason.LocalEnded, EndReason.RemoteEnded, EndReason.Unanswered,
            EndReason.AnsweredElsewhere, EndReason.DeclinedElsewhere,
            EndReason.Filtered(FilterCause.POLICY), EndReason.Failed(error),
        )
        assertEquals(8, reasons.toSet().size)
        assertEquals(error, EndReason.Failed(error).error)
        assertEquals(FilterCause.POLICY, EndReason.Filtered(FilterCause.POLICY).cause)
        val ended = Lifecycle.Ended(EndReason.Failed(error), Instant.parse("2026-11-17T12:00:10Z"))
        assertEquals(EndReason.Failed(error), ended.reason)
    }

    @Test
    fun `actions carry requested values while Answer and Join stay separate`() {
        assertNotEquals(Action.Answer as Action, Action.Join as Action)
        assertEquals(true, Action.Hold(true).held)
        assertEquals(false, Action.Mute(false).muted)
        assertEquals(true, Action.Video(true).enabled)
        assertNotEquals(Action.Hold(true), Action.Hold(false))
        assertNotEquals(Action.Mute(true), Action.Mute(false))
        assertNotEquals(Action.Video(true), Action.Video(false))
        val tones = Action.Tones(DTMFSequence("0123456789*#ABCD"))
        assertEquals("0123456789*#ABCD", tones.digits.value)
        listOf("", "1,2", "a", "1 2", "１２").forEach {
            assertThrows(IllegalArgumentException::class.java) { DTMFSequence(it) }
        }
        assertEquals(Action.End, Action.End)
    }

    @Test
    fun `typed errors preserve correlation and never conflate refusal timeout or service failure`() {
        val actionID = ActionID("answer-1")
        val errors = listOf(
            CallError.UnknownCall(CallID("missing")),
            CallError.InvalidTransition(LifecycleKind.ENDED),
            CallError.Unsupported(Feature.TONES),
            CallError.PermissionRequired(MediaPermission.MICROPHONE),
            CallError.Refused(RefusalReason.NotAllowed),
            CallError.AuthorityUnavailable(AuthorityFailure.CREDENTIAL_UNAVAILABLE),
            CallError.ClaimTimedOut(actionID),
            CallError.PlacementFailed(PlacementFailure.UNAVAILABLE),
            CallError.DeadlineExceeded(TimedStage.RECONCILIATION),
            CallError.MediaFailed(MediaStage.PREPARATION, MediaFailure.INVALID_CREDENTIALS),
            CallError.RemoteIdentityConflict(RemoteCallID("alias")),
            CallError.InvalidConfiguration(ConfigurationField.ANSWER_BUDGET),
            CallError.SystemFailed(SystemFailure.Android(SystemOperation.REMOVAL, 7)),
            CallError.BridgeUnavailable,
        )
        assertEquals(14, errors.toSet().size)
        assertEquals(actionID, CallError.ClaimTimedOut(actionID).actionID)
        assertEquals(RemoteCallID("alias"), CallError.RemoteIdentityConflict(RemoteCallID("alias")).remoteID)
        assertEquals(LifecycleKind.ENDED, CallError.InvalidTransition(LifecycleKind.ENDED).state)
        assertEquals(Feature.TONES, CallError.Unsupported(Feature.TONES).feature)
        assertEquals(MediaPermission.CAMERA, CallError.PermissionRequired(MediaPermission.CAMERA).permission)
        val media = CallError.MediaFailed(MediaStage.PREPARATION, MediaFailure.TRANSPORT)
        assertEquals(MediaStage.PREPARATION, media.stage)
        assertEquals(MediaFailure.TRANSPORT, media.cause)
        val android = SystemFailure.Android(SystemOperation.REMOVAL, 7)
        assertEquals(7, android.nativeCode)
        assertNotEquals(android as SystemFailure, SystemFailure.IOS(SystemOperation.REMOVAL, 7))
    }

    @Test
    fun `all refusal outcomes remain typed rather than throwing`() {
        val refusals = listOf(RefusalReason.AnsweredElsewhere, RefusalReason.DeclinedElsewhere, RefusalReason.NotAllowed)
        assertEquals(3, refusals.toSet().size)
        refusals.forEach { reason ->
            val outcome: Outcome<Unit, CallError> = Outcome.Failure(CallError.Refused(reason))
            when (outcome) {
                is Outcome.Success -> error("Refusal unexpectedly succeeded")
                is Outcome.Failure -> assertEquals(CallError.Refused(reason), outcome.error)
            }
        }
        val success: Outcome<CallID, CallError> = Outcome.Success(CallID("placed"))
        val value = when (success) {
            is Outcome.Success -> success.value
            is Outcome.Failure -> error("Success unexpectedly failed: ${success.error}")
        }
        assertEquals(CallID("placed"), value)
    }
}
