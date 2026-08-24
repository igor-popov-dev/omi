package com.friend.ios.voicecall

import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.telecom.TelecomManager
import android.util.Log

/**
 * The telecom Connection for one voice-mode session. Thin by design: every
 * lifecycle event is forwarded to [VoiceCallController]; this class only owns
 * the two telecom-specific behaviors that must live on the Connection itself:
 *
 *  * Speakerphone by default (Igor's 24.08 decision): a session started with
 *    no headset would otherwise route to the EARPIECE like a private phone
 *    call — forced to SPEAKER once, on the first audio-state callback, so a
 *    later manual route change by the user is respected.
 *  * No HOLD capability, deliberately: when the user answers a real cellular
 *    call, telecom then *disconnects* this connection instead of holding it —
 *    which is exactly the session policy (end, don't pause; the conversation
 *    is already mirrored to chat, resuming is one pendant tap).
 */
class OmiVoiceConnection(private val controller: VoiceCallController) : Connection() {

    private var forcedSpeaker = false

    init {
        connectionProperties = PROPERTY_SELF_MANAGED
        audioModeIsVoip = true
        setCallerDisplayName("Omi", TelecomManager.PRESENTATION_ALLOWED)
    }

    override fun onCallAudioStateChanged(state: CallAudioState?) {
        if (state == null) return
        if (!forcedSpeaker) {
            forcedSpeaker = true
            val headsetRoutes = CallAudioState.ROUTE_BLUETOOTH or CallAudioState.ROUTE_WIRED_HEADSET
            if (state.supportedRouteMask and headsetRoutes == 0) {
                Log.i(TAG, "no headset route available; defaulting to speakerphone")
                setAudioRoute(CallAudioState.ROUTE_SPEAKER)
            }
        }
    }

    /** Telecom asked us to disconnect (answered real call, system policy). */
    override fun onDisconnect() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        controller.onNativeEnd("telecom_disconnect")
    }

    /** No hold support declared, but handle it defensively: a hold request is
     *  treated as "a real call needs the audio" — same policy, end the session. */
    override fun onHold() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        controller.onNativeEnd("telecom_hold")
    }

    override fun onAbort() {
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        destroy()
        controller.onNativeEnd("telecom_abort")
    }

    companion object {
        private const val TAG = "OmiVoiceConnection"
    }
}
