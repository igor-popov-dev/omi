package com.friend.ios.voicecall

import android.app.Application
import android.content.ComponentName
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log

/**
 * Runs one free-form voice-mode session as a self-managed telecom call, so the
 * OS treats the assistant conversation like an ongoing phone call: hang-up in
 * the shade and on the lock screen (CallStyle, see [VoiceCallForegroundService]),
 * telecom-owned audio routing, and a microphone that stays legal when the app
 * is backgrounded (design: ~/omi-jarvis/docs/voice-call-mode-design.md).
 *
 * Singleton with the same rendezvous discipline as
 * [com.friend.ios.phonemic.PhoneMicController]: the system instantiates
 * [OmiVoiceConnectionService] itself, so the service must be able to find the
 * live controller without an Activity in the picture.
 *
 * FAIL-OPEN BY DESIGN, like the player's AudioFocusCoordinator: the call shell
 * is UX plus background-mic legality, not a prerequisite for audio. Every
 * telecom refusal or exception resolves `start` with `false` and the voice
 * mode carries on without a call — a session that talks without a system call
 * notification is still a working session.
 *
 * All entry points run on the main thread (Pigeon calls, telecom callbacks,
 * the foreground service's hang-up action), so there is no locking here —
 * same reasoning as [com.friend.ios.voiceplayer.StreamingPcmPlayerController].
 */
class VoiceCallController private constructor(private val application: Application) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var flutterApi: VoiceCallSessionFlutterApi? = null

    private var activeSessionId: Long? = null
    private var connection: OmiVoiceConnection? = null

    /** A `start` waiting for telecom to call [onCreateOutgoingConnection] back.
     *  [cancelled] is the stop-during-start race guard (the telecom twin of the
     *  orphaned-capture race already fixed in `free_form_voice_mode.dart`): an
     *  `end` that lands while telecom is still building the call marks the
     *  pending start, and the connection is disconnected the moment it is
     *  born instead of becoming an orphaned call nobody owns. */
    private class PendingStart(val sessionId: Long, val callback: (Result<Boolean>) -> Unit) {
        var cancelled = false
    }

    private var pendingStart: PendingStart? = null
    private val pendingStartTimeout = Runnable { failPendingStart("telecom did not call back in time") }

    fun bindFlutterApi(api: VoiceCallSessionFlutterApi) {
        flutterApi = api
    }

    fun unbindFlutterApi() {
        flutterApi = null
    }

    private val telecomManager: TelecomManager
        get() = application.getSystemService(TelecomManager::class.java)

    private fun accountHandle() = PhoneAccountHandle(
        ComponentName(application, OmiVoiceConnectionService::class.java),
        PHONE_ACCOUNT_ID,
    )

    /** Idempotent: re-registering the same handle just overwrites the account. */
    private fun registerPhoneAccount() {
        val account = PhoneAccount.builder(accountHandle(), PHONE_ACCOUNT_LABEL)
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .build()
        telecomManager.registerPhoneAccount(account)
    }

    fun start(sessionId: Long, callback: (Result<Boolean>) -> Unit) {
        // Defensive, mirroring StreamingPcmPlayerController.start: a stray start
        // while a call is live tears the old one down rather than leaking it.
        if (activeSessionId != null) {
            Log.w(TAG, "start($sessionId): replacing still-live call session $activeSessionId")
            teardown()
        }
        failPendingStart("superseded by start($sessionId)")
        try {
            registerPhoneAccount()
            val handle = accountHandle()
            if (!telecomManager.isOutgoingCallPermitted(handle)) {
                // Typically: a real cellular call is already active. Decision
                // 24.08: the voice mode still runs, just without the call shell.
                Log.i(TAG, "start($sessionId): outgoing call not permitted; running without a call shell")
                callback(Result.success(false))
                return
            }
            pendingStart = PendingStart(sessionId, callback)
            mainHandler.postDelayed(pendingStartTimeout, PENDING_START_TIMEOUT_MS)
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
            }
            telecomManager.placeCall(Uri.fromParts("sip", "assistant", null), extras)
        } catch (e: Exception) {
            Log.w(TAG, "start($sessionId) failed; running without a call shell: ${e.message}")
            pendingStart = null
            mainHandler.removeCallbacks(pendingStartTimeout)
            callback(Result.success(false))
        }
    }

    fun end(sessionId: Long, callback: (Result<Unit>) -> Unit) {
        // Idempotent: a sessionId that isn't the active one (already ended, or
        // never got a call because start returned false) is a harmless no-op.
        if (activeSessionId == sessionId) {
            teardown()
        }
        // Stop during start: telecom hasn't built the connection yet — mark the
        // pending start so [onCreateOutgoingConnection] disconnects it at birth.
        pendingStart?.let { if (it.sessionId == sessionId) it.cancelled = true }
        callback(Result.success(Unit))
    }

    /** Telecom created our outgoing connection — the call now exists. */
    fun onCreateOutgoingConnection(): OmiVoiceConnection {
        val pending = pendingStart
        pendingStart = null
        mainHandler.removeCallbacks(pendingStartTimeout)

        val conn = OmiVoiceConnection(this)
        if (pending?.cancelled == true) {
            // The session ended while telecom was building the call — telecom
            // still needs a Connection object back, but it dies at birth.
            Log.i(TAG, "call for session ${pending.sessionId} cancelled before creation")
            conn.setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
            conn.destroy()
            pending.callback(Result.success(false))
            return conn
        }
        conn.setActive()
        connection = conn
        activeSessionId = pending?.sessionId
        VoiceCallForegroundService.start(application)
        Log.i(TAG, "call active for session ${pending?.sessionId}")
        pending?.callback?.invoke(Result.success(true))
        return conn
    }

    fun onCreateOutgoingConnectionFailed() = failPendingStart("onCreateOutgoingConnectionFailed")

    /** Hang-up in the CallStyle notification. */
    fun onHangUpFromNotification() = onNativeEnd("notification_hang_up")

    /** Telecom tore the call down (answered real call, system policy) or the
     *  Connection ended outside [end] for any other native reason. */
    fun onNativeEnd(reason: String) {
        val sessionId = activeSessionId ?: return
        Log.i(TAG, "call for session $sessionId ended natively: $reason")
        teardown()
        flutterApi?.onEnded(sessionId, reason) {} ?: Log.w(TAG, "onEnded($sessionId) dropped: no Flutter API bound")
    }

    /** Flutter engine death: the Dart session is gone, so the call shell must
     *  not outlive it (mirrors StreamingPcmPlayerController.shutdown). */
    fun shutdown() {
        if (activeSessionId != null) teardown()
        failPendingStart("shutdown")
    }

    private fun failPendingStart(reason: String) {
        val pending = pendingStart ?: return
        pendingStart = null
        mainHandler.removeCallbacks(pendingStartTimeout)
        Log.w(TAG, "call for session ${pending.sessionId} not established ($reason); running without a call shell")
        pending.callback(Result.success(false))
    }

    private fun teardown() {
        connection?.let {
            // Safe on a connection telecom already disconnected — setDisconnected
            // on a DISCONNECTED connection is a no-op.
            it.setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            it.destroy()
        }
        connection = null
        activeSessionId = null
        VoiceCallForegroundService.stop(application)
    }

    companion object {
        private const val TAG = "VoiceCallController"
        private const val PHONE_ACCOUNT_ID = "omi_voice_mode"
        private const val PHONE_ACCOUNT_LABEL = "Omi Voice Mode"
        private const val PENDING_START_TIMEOUT_MS = 5000L

        @Volatile
        private var _instance: VoiceCallController? = null

        val instance: VoiceCallController
            get() = _instance ?: throw IllegalStateException("VoiceCallController not initialized")

        val isInitialized: Boolean
            get() = _instance != null

        fun initialize(application: Application) {
            if (_instance == null) {
                synchronized(this) {
                    if (_instance == null) {
                        _instance = VoiceCallController(application)
                    }
                }
            }
        }
    }
}
