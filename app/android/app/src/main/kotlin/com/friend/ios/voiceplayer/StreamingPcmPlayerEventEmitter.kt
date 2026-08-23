package com.friend.ios.voiceplayer

import android.os.Handler
import android.util.Log

/**
 * The only object that touches [StreamingPcmPlayerFlutterApi]. Every send is
 * posted onto the caller-supplied main [Handler] and null-guarded — [unbind]
 * nulls the api reference on main, so a send racing a torn-down engine drops
 * harmlessly instead of touching a dead Flutter engine (same shape as
 * [com.friend.ios.phonemic.PhoneMicEventEmitter], simplified: this class has no
 * frame stream to epoch-gate, only two one-shot events per session, and the
 * controller already does the session-id fencing before calling in here).
 */
class StreamingPcmPlayerEventEmitter(private val mainHandler: Handler) {
    private var api: StreamingPcmPlayerFlutterApi? = null

    fun bind(api: StreamingPcmPlayerFlutterApi) {
        this.api = api
    }

    fun unbind() {
        this.api = null
    }

    fun emitStarted(sessionId: Long) {
        mainHandler.post {
            api?.onStarted(sessionId) { result ->
                result.exceptionOrNull()?.let { Log.w(TAG, "onStarted delivery failed: ${it.message}") }
            }
        }
    }

    fun emitDrained(sessionId: Long) {
        mainHandler.post {
            api?.onDrained(sessionId) { result ->
                result.exceptionOrNull()?.let { Log.w(TAG, "onDrained delivery failed: ${it.message}") }
            }
        }
    }

    fun emitAudioFocusLost(sessionId: Long) {
        mainHandler.post {
            api?.onAudioFocusLost(sessionId) { result ->
                result.exceptionOrNull()?.let { Log.w(TAG, "onAudioFocusLost delivery failed: ${it.message}") }
            }
        }
    }

    companion object {
        private const val TAG = "StreamingPcmPlayerEmit"
    }
}
