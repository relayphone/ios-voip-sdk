package com.relayphone.voip.expo

import com.relayphone.voip.CallID
import com.relayphone.voip.Wire
import java.io.File
import kotlin.time.Instant
import kotlinx.serialization.json.*
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

internal class PushIntakeTest {
    @Test
    fun `only recognized eligible invitations decode`() {
        val elapsed = Instant.fromEpochMilliseconds(1_000)
        val received = Instant.parse("2026-11-18T00:00:44.999Z")
        val push = PushEnvelope.decode(pushFixture, received, elapsed) as PushEnvelope.Invitation
        assertEquals(CallID("call-α"), push.input.callID)
        assertEquals("invite-a", push.input.eventID.value)
        assertEquals("credential-reference-a", push.credentialRef)
        assertEquals(Instant.fromEpochMilliseconds(1_001), push.input.ringDeadline)
        for (name in listOf("expiry", "pushVersion", "pushCalendar", "pushInterval")) {
            assertEquals(PushEnvelope.Invalid, PushEnvelope.decode(fcm("invalid/$name.json"), received, elapsed), name)
        }
        assertEquals(PushEnvelope.Invalid, PushEnvelope.decode(pushFixture + ("value" to "{"), received, elapsed))
        assertEquals(PushEnvelope.Unrelated, PushEnvelope.decode(mapOf("kind" to "message"), received, elapsed))
        val receiptCases = Wire.json.parseToJsonElement(fixtures.resolve("push-receipts.json").readText()).jsonArray
        for (case in receiptCases.map { it.jsonObject }) {
            val result = PushEnvelope.decode(pushFixture, Instant.parse(case.text("receivedAt")), elapsed)
            assertEquals(case.read<Boolean>("eligible"), result is PushEnvelope.Invitation, case.toString())
        }
    }

    @Test
    fun `registration persists generations and fences stale or failed retries`() {
        val fixture = readFixture("valid/pushRegistration.json").obj("value")
        var saved = PushRegistration.Saved()
        val installation = fixture.text("installationID")
        fun registry(channel: String = "fcm", installationID: String = installation) =
            PushRegistration(installationID, channel, saved) { saved = it }
        var state = registry()
        assertEquals("registering", state.value().text("kind"))
        val attempt = state.begin()
        assertTrue(state.complete(attempt, "provider-token-a"))
        val initial = state.changed("provider-token-a")
        assertEquals(1L, initial.generation)
        state = registry()
        assertEquals(initial, state.changed("provider-token-a"))
        val stale = state.begin()
        val rotated = state.changed("provider-token-b")
        assertFalse(state.complete(stale, "provider-token-a"))
        state.completeUpload(initial, FcmUploadResult.ACKNOWLEDGED)
        assertEquals("pending", state.value().obj("upload").text("kind"))
        state.completeUpload(rotated, FcmUploadResult.SERVICE_REJECTED)
        assertEquals("serviceRejected", state.value().obj("upload").text("reason"))
        state.completeUpload(rotated, FcmUploadResult.ACKNOWLEDGED)
        state.completeUpload(rotated, FcmUploadResult.OFFLINE)
        assertEquals(JsonObject(fixture + ("tokenID" to encode(rotated.tokenID))), registry().value())
        assertFalse(state.value().toString().contains("provider-token"))
        assertNotEquals(initial.tokenID, rotated.tokenID)
        state.invalidate()
        state.invalidate()
        assertEquals("invalidated", registry().value().text("kind"))
        assertEquals(3L, registry().changed("provider-token-c").generation)

        val other = PushRegistration("new-installation", "fcm", PushRegistration.Saved()) {}
        assertEquals(1L, other.changed("provider-token-c").generation)
        assertNotEquals(state.installationID, other.installationID)
        val otherChannel = PushRegistration(installation, "apnsVoip", PushRegistration.Saved()) {}
        assertEquals(1L, otherChannel.changed("provider-token-c").generation)
    }
}

private val fixtures = File(System.getProperty("spec.v1"))
internal val pushFixture = fcm("valid/pushEnvelope.json")
internal fun readFixture(path: String) = Wire.json.parseToJsonElement(fixtures.resolve(path).readText()).jsonObject
private fun fcm(path: String) = readFixture(path).let {
    mapOf("kind" to it.text("kind"), "version" to it.text("version"), "value" to it.getValue("value").toString())
}
