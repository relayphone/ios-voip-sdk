package com.relayphone.voip.system

import androidx.core.telecom.CallEndpointCompat
import com.relayphone.voip.*
import com.relayphone.voip.runtime.*
import kotlin.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

@OptIn(ExperimentalCoroutinesApi::class)
internal class TelecomAudioTest {
    @Test
    fun `routes use stable per-call identifiers and revise only when observations change`() = runTest {
        val (port, backend, runtime) = connected()
        val seen = mutableListOf<CallAudioRoutes>()
        backgroundScope.launch { port.routes.collect { seen += it } }
        runCurrent()
        val initial = port.routes.value
        assertEquals(CallAudioRouteType.RECEIVER, initial.current?.type)
        assertEquals(listOf(CallAudioRouteType.RECEIVER, CallAudioRouteType.SPEAKER), initial.routes.map { it.type })
        val receiverID = initial.routes.first().id
        val speakerID = initial.routes.last().id

        assertEquals(Outcome.Success(Unit), port.selectRoute(speakerID))
        assertEquals("speaker", backend.audio.selection)
        assertEquals(initial, port.routes.value)
        backend.audio.currentEndpoint.value = speaker
        runCurrent()
        assertEquals(speakerID, port.routes.value.current?.id)
        assertEquals(initial.revision + 1, port.routes.value.revision)

        backend.audio.availableEndpoints.value = listOf(speaker, wired, bluetooth)
        runCurrent()
        assertEquals(listOf(CallAudioRouteType.SPEAKER, CallAudioRouteType.WIRED, CallAudioRouteType.BLUETOOTH),
            port.routes.value.routes.map { it.type })
        assertEquals(Outcome.Failure(CallError.SystemFailed(SystemFailure(Platform.ANDROID, SystemOperation.AUDIO))),
            port.selectRoute(receiverID))
        backend.audio.currentEndpoint.value = bluetooth
        runCurrent()
        assertEquals("Headset", port.routes.value.current?.name)
        val bluetoothID = port.routes.value.current?.id
        backend.audio.currentEndpoint.value = bluetooth.copy()
        runCurrent()
        assertEquals(initial.revision + 3, port.routes.value.revision)

        backend.audio.availableEndpoints.value = listOf(receiver, speaker)
        runCurrent()
        backend.audio.currentEndpoint.value = receiver
        runCurrent()
        assertEquals(receiverID, port.routes.value.current?.id)
        backend.audio.availableEndpoints.value = listOf(receiver, speaker, bluetooth)
        runCurrent()
        assertEquals(bluetoothID, port.routes.value.routes.last().id)
        assertEquals((initial.revision..port.routes.value.revision).toList(), seen.map { it.revision })

        runtime.submit(Input.Request(Action.Hold(invitation.callID, true), ActionID("hold"), supported = true))
        runCurrent()
        assertNull(port.routes.value.current)
        runtime.submit(Input.Request(Action.Hold(invitation.callID, false), ActionID("resume"), supported = true))
        runCurrent()
        assertEquals(receiverID, port.routes.value.current?.id)
        assertEquals(listOf(true, false), backend.audio.holdChanges)

        runtime.close()
        assertEquals(emptyList<CallAudioRoute>(), port.routes.value.routes)
        assertNull(port.routes.value.current)
        assertTrue(port.selectRoute(speakerID) is Outcome.Failure)
    }

    @Test
    fun `mute waits for native confirmation and publishes each app or system receipt once`() = runTest {
        val (port, backend, runtime) = connected()
        val receipts = receipts(runtime)
        val mute = Action.Mute(invitation.callID, true)
        val app = async { port.perform(mute) }
        runCurrent()
        assertFalse(app.isCompleted)
        assertFalse(runtime.snapshot().state.calls.getValue(invitation.callID).muted)
        assertTrue(receipts.isEmpty())

        backend.audio.muteAllowed.complete(Unit)
        val confirmed = app.await() as Outcome.Success
        runCurrent()
        assertEquals(ActionOrigin.APP, confirmed.value.origin)
        assertEquals(mute, confirmed.value.action)
        assertTrue(runtime.snapshot().state.calls.getValue(invitation.callID).muted)
        assertEquals(listOf(confirmed.value), receipts)

        backend.audio.isMuted.value = false
        runCurrent()
        assertFalse(runtime.snapshot().state.calls.getValue(invitation.callID).muted)
        assertEquals(listOf(ActionOrigin.APP, ActionOrigin.SYSTEM), receipts.map { it.origin })
        assertEquals(Action.Mute(invitation.callID, false), receipts.last().action)
        assertEquals(listOf(true), backend.audio.muteRequests)
        runtime.close()
    }

    @Test
    fun `tones publish after the local send and a native failure produces no receipt`() = runTest {
        val (port, backend, runtime) = connected()
        val receipts = receipts(runtime)
        val tones = Action.Tones(invitation.callID, DTMFSequence("12*#Ab"))
        val send = async { port.perform(tones) }
        runCurrent()
        assertEquals(tones.digits, backend.audio.sent)
        assertFalse(send.isCompleted)
        assertTrue(receipts.isEmpty())

        backend.audio.toneAllowed.complete(Unit)
        val confirmed = send.await() as Outcome.Success
        runCurrent()
        assertEquals(tones, confirmed.value.action)
        assertEquals(listOf(confirmed.value), receipts)
        backend.audio.toneError = 47
        assertEquals(Outcome.Failure(CallError.SystemFailed(SystemFailure(Platform.ANDROID, SystemOperation.AUDIO, 47))),
            port.perform(tones))
        runCurrent()
        assertEquals(listOf(confirmed.value), receipts)
        runtime.close()
    }

    private fun TestScope.receipts(runtime: CallRuntime): List<ActionReceipt> {
        val receipts = mutableListOf<ActionReceipt>()
        backgroundScope.launch {
            runtime.observe(runtime.snapshot().cursor).collect {
                if (it is RuntimeFrame.ActionPerformed) receipts += it.receipt
            }
        }
        runCurrent()
        return receipts
    }

    private suspend fun TestScope.connected(): Triple<TelecomPort<String>, FakeTelecom, CallRuntime> {
        lateinit var runtime: CallRuntime
        val backend = FakeTelecom()
        val port = TelecomPort(backend, { runtime.submit(it) }, StandardTestDispatcher(testScheduler))
        val media = object : MediaPort {
            override suspend fun prepare(request: Effect.PrepareMedia) = Outcome.Success(Unit)
            override suspend fun close(request: Effect.CloseMedia) = Unit
            override suspend fun sendTones(request: Effect.SendTones) = port.sendTones(request)
        }
        val authority = object : AuthorityPort {
            override suspend fun claim(request: Effect.RequestClaim) = AnswerDecision.Allow(AttemptID("permit"))
            override suspend fun reconcile(request: Effect.Reconcile) = Reconciliation.Unknown
            override suspend fun release(request: Effect.ReleasePermit) = Unit
        }
        runtime = (CallRuntime.start(
            Configuration(Budgets(), OutgoingMedia.WHEN_PROVIDED, ConnectionAuthority.APPLICATION, 1, false),
            backgroundScope, port, authority, media, PresentationPort {},
            MonotonicClock { Instant.fromEpochMilliseconds(testScheduler.currentTime) },
        ) as Outcome.Success).value
        assertEquals(Outcome.Success(IncomingResult.Admitted(invitation.callID)), runtime.reportIncoming(invitation))
        assertTrue(port.answerWithReceipt(invitation.callID) is Outcome.Success)
        runtime.receive(RemoteEvent.Connected(EventID("connected"), EndTarget.Canonical(invitation.callID)))
        runCurrent()
        assertTrue(runtime.snapshot().state.calls.getValue(invitation.callID).lifecycle is Lifecycle.Connected)
        return Triple(port, backend, runtime)
    }

    private class FakeTelecom : TelecomBackend<String> {
        val audio = FakeAudio()
        override suspend fun addCall(call: Call, callbacks: TelecomCallbacks, admitted: (TelecomControl<String>) -> Unit) {
            admitted(object : TelecomControl<String> {
                override val id = "native-${call.id.value}"
                override val audio = this@FakeTelecom.audio
                override suspend fun answer() = Unit
                override suspend fun setHeld(held: Boolean) = Unit
                override suspend fun disconnect(cause: TelecomEnd) = Unit
            })
            awaitCancellation()
        }
    }

    private class FakeAudio : TelecomAudioControl {
        override val currentEndpoint = MutableStateFlow(receiver)
        override val availableEndpoints = MutableStateFlow(listOf(receiver, speaker))
        override val isMuted = MutableStateFlow(false)
        val muteAllowed = CompletableDeferred<Unit>()
        val muteRequests = mutableListOf<Boolean>()
        val holdChanges = mutableListOf<Boolean>()
        val toneAllowed = CompletableDeferred<Unit>()
        var toneError: Int? = null
        var selection: String? = null
        var sent: DTMFSequence? = null

        override suspend fun selectEndpoint(id: String) { selection = id }

        override suspend fun setMuted(muted: Boolean) {
            muteRequests += muted
            muteAllowed.await()
            isMuted.value = muted
        }

        override fun holdChanged(held: Boolean) { holdChanges += held }

        override suspend fun sendTones(digits: DTMFSequence) {
            sent = digits
            toneError?.let { throw NativeTelecomFailure(it) }
            toneAllowed.await()
        }
    }

    private companion object {
        val invitation = Input.Incoming(
            CallID("audio-call"), EventID("invitation"), CallingLine(AccountID("account"), LineID("line"), "Work"),
            Party(PartyID("caller"), Handle.Opaque("caller"), "Caller"),
        )
        val receiver = TelecomEndpoint("receiver", "Earpiece", CallEndpointCompat.TYPE_EARPIECE)
        val speaker = TelecomEndpoint("speaker", "Speaker", CallEndpointCompat.TYPE_SPEAKER)
        val wired = TelecomEndpoint("wired", "Wired headset", CallEndpointCompat.TYPE_WIRED_HEADSET)
        val bluetooth = TelecomEndpoint("bt", "Headset", CallEndpointCompat.TYPE_BLUETOOTH)
    }
}
