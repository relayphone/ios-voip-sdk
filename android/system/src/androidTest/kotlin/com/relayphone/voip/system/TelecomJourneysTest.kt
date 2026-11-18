package com.relayphone.voip.system

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.ParcelUuid
import android.os.SystemClock
import androidx.core.telecom.CallsManager
import androidx.test.platform.app.InstrumentationRegistry
import com.relayphone.voip.AccountID
import com.relayphone.voip.Action
import com.relayphone.voip.ActionID
import com.relayphone.voip.AttemptID
import com.relayphone.voip.Budgets
import com.relayphone.voip.Call
import com.relayphone.voip.CallError
import com.relayphone.voip.CallID
import com.relayphone.voip.CallingLine
import com.relayphone.voip.Configuration
import com.relayphone.voip.ConnectionAuthority
import com.relayphone.voip.Effect
import com.relayphone.voip.EndReason
import com.relayphone.voip.EventID
import com.relayphone.voip.Handle
import com.relayphone.voip.Input
import com.relayphone.voip.Lifecycle
import com.relayphone.voip.LineID
import com.relayphone.voip.Outcome
import com.relayphone.voip.OutgoingMedia
import com.relayphone.voip.Party
import com.relayphone.voip.PartyID
import com.relayphone.voip.Preparation
import com.relayphone.voip.runtime.AnswerDecision
import com.relayphone.voip.runtime.AuthorityPort
import com.relayphone.voip.runtime.CallRuntime
import com.relayphone.voip.runtime.MediaPort
import com.relayphone.voip.runtime.MonotonicClock
import com.relayphone.voip.runtime.PresentationPort
import com.relayphone.voip.runtime.Reconciliation
import com.relayphone.voip.runtime.SystemPort
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TelecomJourneysTest {
    @Test
    fun incomingRingsAnswersAndEnds() = runBlocking {
        withRegisteredSystem { runtime, system, authority ->
            report(runtime)
            awaitTelecom("RINGING")
            awaitNotification(present = true)
            assertEquals(Outcome.Success(Unit), system.answer(id))
            runtime.awaitLifecycle { it == Lifecycle.Connecting }
            awaitTelecom("ACTIVE")
            assertEquals(1, authority.claims.get())
            end(runtime)
            awaitEnd(runtime)
        }
    }

    @Test
    fun outgoingWaitsForApplicationConnectionAndEnds() = runBlocking {
        withRegisteredSystem { runtime, _, _ ->
            check(runtime.submit(Input.Request(Action.Start(id, line, party), ActionID("start"))))
            runtime.awaitLifecycle { it == Lifecycle.Dialing }
            awaitTelecom("DIALING", "CONNECTING")
            check(runtime.submit(Input.ProvideMedia(id)))
            withTimeout(12.seconds) { runtime.state.first { it.calls[id]?.media?.preparation == Preparation.PREPARED } }
            repeat(4) {
                val observed = telecomStates()
                assertTrue("Prepared media left unexpected Telecom state $observed",
                    observed == listOf("DIALING") || observed == listOf("CONNECTING"))
                delay(100)
            }
            check(runtime.submit(Input.Connected(id, EventID("connect"), ConnectionAuthority.APPLICATION)))
            runtime.awaitLifecycle { it is Lifecycle.Connected }
            awaitTelecom("ACTIVE")
            end(runtime)
            awaitEnd(runtime)
        }
    }

    @Test
    fun appAnswerAndCallbackEchoShareOneClaim() = runBlocking {
        val nativeAnswers = AtomicInteger()
        withSystem(create = { submit ->
            withContext(Dispatchers.IO) {
                val calls = CallsManager(context)
                calls.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE, compatibilityBound)
                val backend = CoreTelecomBackend(calls, AdmissionNotification(context))
                TelecomPort(EchoAnswer(backend, nativeAnswers), submit)
            }
        }) { runtime, system, authority ->
            report(runtime)
            awaitTelecom("RINGING")
            assertEquals(Outcome.Success(Unit), system.answer(id))
            awaitTelecom("ACTIVE")
            assertEquals(1, authority.claims.get())
            assertEquals(1, nativeAnswers.get())
            end(runtime)
            awaitEnd(runtime)
        }
    }

    private suspend fun report(runtime: CallRuntime) {
        check(runtime.submit(Input.Incoming(id, EventID("invite"), line, party)))
        runtime.awaitLifecycle { it == Lifecycle.Ringing }
    }

    private suspend fun awaitEnd(runtime: CallRuntime) {
        runtime.awaitLifecycle { it is Lifecycle.Ended && it.reason == EndReason.LocalEnded }
        withTimeout(12.seconds) { runtime.state.first { id in it.systemRemoved } }
        awaitTelecom()
        awaitNotification(present = false)
    }

    private fun end(runtime: CallRuntime) {
        check(runtime.submit(Input.Request(Action.End(id), ActionID("end"))))
    }

    private suspend fun CallRuntime.awaitLifecycle(matches: (Lifecycle) -> Boolean) {
        withTimeout(12.seconds) { state.first { it.calls[id]?.lifecycle?.let(matches) == true } }
    }

    private suspend fun awaitTelecom(vararg expected: String) {
        var observed = emptyList<String>()
        val matched = withTimeoutOrNull(10.seconds) {
            while (true) {
                observed = telecomStates()
                if (expected.isEmpty() && observed.isEmpty() ||
                    observed.size == 1 && observed.single() in expected
                ) return@withTimeoutOrNull true
                delay(100)
            }
        }
        assertTrue("Expected Telecom ${expected.toList()}, observed $observed", matched == true)
    }

    private fun telecomStates(): List<String> {
        val dump = shell("dumpsys telecom")
        val lines = dump.lineSequence().dropWhile { it.trim() != "mCalls:" }
        check(lines.firstOrNull() != null) { "Telecom dump did not include live calls" }
        val live = lines.drop(1).takeWhile { it.trimStart().startsWith("[Call id=") }
        return live.filter { it.contains("tpac=ComponentInfo{${context.packageName}/") }
            .map { checkNotNull(statePattern.find(it)).groupValues[1] }.toList()
    }

    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        instrumentation.uiAutomation.executeShellCommand(command),
    ).bufferedReader().use { it.readText() }

    private suspend fun awaitNotification(present: Boolean) {
        val manager = checkNotNull(context.getSystemService(NotificationManager::class.java))
        val matched = withTimeoutOrNull(5.seconds) {
            while (manager.activeNotifications.any { it.tag == id.value } != present) delay(100)
            true
        }
        assertTrue("Expected admission notification present=$present", matched == true)
    }

    private suspend fun withRegisteredSystem(
        scenario: suspend (CallRuntime, AndroidTelecomSystem, Authority) -> Unit,
    ) = withSystem(
        create = { AndroidTelecomSystem.register(context, compatibilityBound, it) },
        scenario,
    )

    private suspend fun <S : SystemPort> withSystem(
        create: suspend ((Input) -> Boolean) -> S,
        scenario: suspend (CallRuntime, S, Authority) -> Unit,
    ) = coroutineScope {
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
        lateinit var runtime: CallRuntime
        val system = create { runtime.submit(it) }
        val authority = Authority()
        runtime = CallRuntime.start(
            Configuration(Budgets(), OutgoingMedia.WHEN_PROVIDED, ConnectionAuthority.APPLICATION, 1, false),
            this, system, authority, Media(), PresentationPort {},
            MonotonicClock { Instant.fromEpochMilliseconds(SystemClock.elapsedRealtime()) },
        ).success()
        try {
            withTimeout(25.seconds) { scenario(runtime, system, authority) }
        } finally {
            runtime.close()
        }
    }

    private class EchoAnswer(
        private val backend: TelecomBackend<ParcelUuid>,
        private val nativeAnswers: AtomicInteger,
    ) : TelecomBackend<ParcelUuid> {
        override suspend fun addCall(
            call: Call, callbacks: TelecomCallbacks, admitted: (TelecomControl<ParcelUuid>) -> Unit,
        ) = backend.addCall(call, callbacks) { control ->
            admitted(object : TelecomControl<ParcelUuid> by control {
                override suspend fun answer() {
                    nativeAnswers.incrementAndGet()
                    callbacks.answer()
                    control.answer()
                }
            })
        }
    }

    private class Authority : AuthorityPort {
        val claims = AtomicInteger()
        override suspend fun place(call: Call, request: Effect.RequestPlacement): Outcome<Unit, CallError.PlacementFailed> =
            Outcome.Success(Unit)
        override suspend fun claim(request: Effect.RequestClaim): AnswerDecision {
            claims.incrementAndGet()
            return AnswerDecision.Allow(AttemptID("permit"))
        }
        override suspend fun reconcile(request: Effect.Reconcile): Reconciliation = Reconciliation.Unknown
        override suspend fun release(request: Effect.ReleasePermit) = Unit
    }

    private class Media : MediaPort {
        override suspend fun prepare(request: Effect.PrepareMedia): Outcome<Unit, CallError.MediaFailed> =
            Outcome.Success(Unit)
        override suspend fun close(request: Effect.CloseMedia) = Unit
        override suspend fun sendTones(request: Effect.SendTones): Outcome<Unit, CallError> = Outcome.Success(Unit)
    }

    private companion object {
        val instrumentation get() = InstrumentationRegistry.getInstrumentation()
        val context: Context get() = instrumentation.targetContext
        const val compatibilityBound = 34
        val statePattern = Regex("state=([A-Z_]+),")
        val id = CallID("sample-call")
        val line = CallingLine(AccountID("account"), LineID("work"), "Work")
        val party = Party(PartyID("remote-party"), Handle.Phone("+12025550123"), "Example")
    }
}

private fun <T, E> Outcome<T, E>.success(): T = when (this) {
    is Outcome.Success -> value
    is Outcome.Failure -> error("Expected success, received $error")
}
