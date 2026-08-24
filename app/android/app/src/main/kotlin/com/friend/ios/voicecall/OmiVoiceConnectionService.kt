package com.friend.ios.voicecall

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.util.Log

/**
 * System-instantiated entry point for the self-managed voice-mode call. Thin
 * on purpose: the system may create this service on its own schedule, so all
 * state lives in the [VoiceCallController] singleton and this class only
 * forwards telecom's callbacks to it.
 */
class OmiVoiceConnectionService : ConnectionService() {

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection? {
        if (!VoiceCallController.isInitialized) {
            // Can only happen if telecom calls back after the process was
            // recreated without the app bootstrapping (no Activity yet) —
            // there is no session to attach a call to, so refuse it.
            Log.w(TAG, "onCreateOutgoingConnection with no controller; refusing")
            return null
        }
        return VoiceCallController.instance.onCreateOutgoingConnection()
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        Log.w(TAG, "onCreateOutgoingConnectionFailed")
        if (VoiceCallController.isInitialized) {
            VoiceCallController.instance.onCreateOutgoingConnectionFailed()
        }
    }

    companion object {
        private const val TAG = "OmiVoiceConnSvc"
    }
}
