package com.relayphone.voip.system

import android.content.Context
import android.os.ParcelUuid
import androidx.core.telecom.CallsManager
import com.relayphone.voip.CallError
import com.relayphone.voip.CallID
import com.relayphone.voip.Input
import com.relayphone.voip.Outcome
import com.relayphone.voip.runtime.SystemPort
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Connects the Android Telecom call lifecycle to a [SystemPort]. */
public class AndroidTelecomSystem private constructor(
    private val port: TelecomPort<ParcelUuid>,
) : SystemPort by port {
    /** Answers a ringing call, sharing the receipt with any Telecom Answer callback. */
    public suspend fun answer(callID: CallID): Outcome<Unit, CallError> = port.answer(callID)

    public companion object {
        /**
         * Registers once before starting the calling runtime. Route [submit] to that runtime's inbox.
         * [compatibilityBound] is the highest API level that should use legacy ConnectionService.
         */
        public suspend fun register(
            context: Context,
            compatibilityBound: Int,
            submit: (Input) -> Boolean,
        ): AndroidTelecomSystem = withContext(Dispatchers.IO) {
            require(compatibilityBound >= 33)
            val application = context.applicationContext
            val calls = CallsManager(application)
            calls.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE, compatibilityBound)
            AndroidTelecomSystem(TelecomPort(CoreTelecomBackend(calls, AdmissionNotification(application)), submit))
        }
    }
}
