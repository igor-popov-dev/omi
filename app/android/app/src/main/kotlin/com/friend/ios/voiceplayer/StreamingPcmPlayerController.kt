package com.friend.ios.voiceplayer

import android.os.Handler
import android.util.Log

/**
 * Owns at most one live [StreamingPcmPlayer] and fences every HostApi call and
 * outbound event by session id, mirroring
 * [com.friend.ios.phonemic.PhoneMicController]'s discipline at a much smaller
 * scale (playback has no rebuild-on-interruption story). All methods are called
 * on the Pigeon main thread; this class does not introduce any locking of its
 * own because of that.
 */
class StreamingPcmPlayerController(mainHandler: Handler) {
    companion object {
        private const val TAG = "StreamingPcmPlayerCtrl"
    }

    private val emitter = StreamingPcmPlayerEventEmitter(mainHandler)
    private val callbackHandler = mainHandler

    private var player: StreamingPcmPlayer? = null
    private var activeSessionId: Long? = null

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
            callback(Result.success(Unit))
        } catch (e: Exception) {
            Log.e(TAG, "start($sessionId) failed", e)
            callback(Result.failure(StreamingPcmPlayerPigeonError("track_init_failed", e.message ?: "AudioTrack init failed", null)))
        }
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
