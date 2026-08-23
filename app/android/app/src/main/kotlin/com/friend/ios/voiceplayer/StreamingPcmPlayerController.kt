package com.friend.ios.voiceplayer

import android.content.Context
import android.os.Handler
import android.util.Log

/**
 * Owns at most one live [StreamingPcmPlayer] and fences every HostApi call and
 * outbound event by session id, mirroring
 * [com.friend.ios.phonemic.PhoneMicController]'s discipline at a much smaller
 * scale (playback has no rebuild-on-interruption story). All methods are called
 * on the Pigeon main thread; this class does not introduce any locking of its
 * own because of that.
 *
 * Also owns the [AudioFocusCoordinator] for the live player's session (one
 * focus request per session, requested alongside the player in [start] and
 * abandoned alongside it in [close]/[shutdown] — see that class's doc for why
 * this granularity, not per-turn).
 */
class StreamingPcmPlayerController(mainHandler: Handler, context: Context) {
    companion object {
        private const val TAG = "StreamingPcmPlayerCtrl"
        private const val DUCK_VOLUME = 0.2f
        private const val FULL_VOLUME = 1.0f
    }

    private val emitter = StreamingPcmPlayerEventEmitter(mainHandler)
    private val callbackHandler = mainHandler

    private var player: StreamingPcmPlayer? = null
    private var activeSessionId: Long? = null

    private val audioFocus = AudioFocusCoordinator(
        context = context,
        onStop = { handleAudioFocusStop() },
        onDuck = { player?.setVolume(DUCK_VOLUME) },
        onResume = { player?.setVolume(FULL_VOLUME) },
    )

    // Self-host patch: same session granularity as [audioFocus] — a voice session
    // talks through the user's headset, ambient capture never does.
    private val voiceRoute = VoiceRouteCoordinator(context)

    fun bindFlutterApi(api: StreamingPcmPlayerFlutterApi) = emitter.bind(api)
    fun unbindFlutterApi() = emitter.unbind()

    fun start(sessionId: Long, callback: (Result<Unit>) -> Unit) {
        // Defensive: the Dart side always close()s its current player before
        // starting a new one, but if a stray start() arrives while one is
        // already live, tear the old one down first rather than leaking it.
        player?.let {
            Log.w(TAG, "start($sessionId): replacing still-live session ${activeSessionId}")
            it.close()
        }
        player = null
        activeSessionId = null
        try {
            player = StreamingPcmPlayer(
                callbackHandler = callbackHandler,
                onStarted = { emitter.emitStarted(sessionId) },
                onDrained = { emitter.emitDrained(sessionId) },
            )
            activeSessionId = sessionId
            audioFocus.request()
            voiceRoute.engage()
            callback(Result.success(Unit))
        } catch (e: Exception) {
            Log.e(TAG, "start($sessionId) failed", e)
            callback(Result.failure(StreamingPcmPlayerPigeonError("track_init_failed", e.message ?: "AudioTrack init failed", null)))
        }
    }

    /** [AudioFocusAction.STOP]: another app permanently claimed focus (or a
     *  transient claim we chose not to try resuming — see [AudioFocusPolicy]'s
     *  doc). Tear the live session down exactly like an explicit [close], then
     *  tell Dart why so the hub session can end cleanly instead of sending
     *  audio into a track nothing will hear. No-op if nothing is live (a
     *  stray/late focus callback after an explicit close already ran). */
    private fun handleAudioFocusStop() {
        val sessionId = activeSessionId ?: return
        player?.close()
        player = null
        activeSessionId = null
        audioFocus.abandon()
        voiceRoute.release()
        emitter.emitAudioFocusLost(sessionId)
    }

    fun enqueuePcm16(bytes: ByteArray, sessionId: Long) {
        if (!isActive(sessionId, "enqueuePcm16")) return
        player?.enqueue(bytes)
    }

    fun flush(sessionId: Long) {
        if (!isActive(sessionId, "flush")) return
        player?.flush()
    }

    fun clear(sessionId: Long) {
        if (!isActive(sessionId, "clear")) return
        player?.clear()
    }

    fun close(sessionId: Long, callback: (Result<Unit>) -> Unit) {
        // Idempotent by design: a sessionId that isn't the active one (already
        // closed, or never started) is a harmless no-op success, not an error —
        // matches the doc comment on the pigeon interface.
        if (activeSessionId == sessionId) {
            player?.close()
            player = null
            activeSessionId = null
            audioFocus.abandon()
            voiceRoute.release()
        }
        callback(Result.success(Unit))
    }

    /** Activity teardown: release any live AudioTrack so playback cannot outlive
     *  the Flutter engine that owns its session bookkeeping (mirrors
     *  [com.friend.ios.phonemic.PhoneMicController.onFlutterEngineDestroyed]). */
    fun shutdown() {
        player?.close()
        player = null
        activeSessionId = null
        audioFocus.abandon()
        voiceRoute.release()
    }

    private fun isActive(sessionId: Long, caller: String): Boolean {
        val active = activeSessionId
        if (active != sessionId) {
            Log.w(TAG, "$caller($sessionId) dropped: active session is $active")
            return false
        }
        return true
    }
}
