package com.relayphone.voip.expo

import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

/** Identifies the FCM token and generation targeted by an authenticated upload. */
data class FcmTokenRegistration(val installationID: String, val generation: Long, val tokenID: String)

enum class FcmUploadResult { ACKNOWLEDGED, OFFLINE, SERVICE_REJECTED, UNKNOWN }

internal class PushRegistration(
    val installationID: String,
    private val channel: String,
    initial: Saved,
    private val save: (Saved) -> Unit,
) {
    @Serializable
    data class Saved(
        val generation: Long = 1,
        val fingerprint: String? = null,
        val tokenID: String? = null,
        val invalidated: Boolean = false,
        val upload: FcmUploadResult? = null,
    )

    private var current = initial
    private var pending: UUID? = null
    private var failed = false

    fun begin(): UUID = UUID.randomUUID().also { pending = it }

    fun complete(attempt: UUID, token: String?): Boolean {
        if (pending != attempt) return false
        pending = null
        if (token != null) changed(token)
        else failed = true
        return true
    }

    fun changed(token: String): FcmTokenRegistration {
        require(token.isNotEmpty())
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(token.toByteArray())
            .joinToString("") { "%02x".format(it) }
        if (fingerprint != current.fingerprint) {
            update(Saved(current.generation + if (current.tokenID == null) 0 else 1,
                fingerprint, UUID.randomUUID().toString()))
        }
        pending = null
        failed = false
        return requireNotNull(target())
    }

    fun invalidate() {
        if (!current.invalidated) update(Saved(current.generation + if (current.tokenID == null) 0 else 1, invalidated = true))
        pending = null
        failed = false
    }

    fun completeUpload(target: FcmTokenRegistration, result: FcmUploadResult) {
        if (target == target() && current.upload != FcmUploadResult.ACKNOWLEDGED)
            update(current.copy(upload = result))
    }

    fun value(): JsonObject = buildJsonObject {
        put("installationID", installationID)
        put("channel", channel)
        put("generation", current.generation)
        val id = current.tokenID
        if (id != null) {
            put("kind", "registered")
            put("tokenID", id)
            put("upload", when (current.upload) {
                null -> message("pending")
                FcmUploadResult.ACKNOWLEDGED -> message("acknowledged")
                FcmUploadResult.OFFLINE -> uploadFailure("offline")
                FcmUploadResult.SERVICE_REJECTED -> uploadFailure("serviceRejected")
                FcmUploadResult.UNKNOWN -> uploadFailure("unknown")
            })
        } else if (current.invalidated) put("kind", "invalidated")
        else if (failed) {
            put("kind", "failed")
            put("reason", "tokenUnavailable")
        } else put("kind", "registering")
    }

    private fun target() = current.tokenID?.let { FcmTokenRegistration(installationID, current.generation, it) }

    private fun update(next: Saved) {
        if (current == next) return
        save(next)
        current = next
    }

    private fun uploadFailure(reason: String) = message("failed", "reason" to JsonPrimitive(reason))
}
