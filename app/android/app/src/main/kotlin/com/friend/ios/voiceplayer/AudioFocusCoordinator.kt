package com.friend.ios.voiceplayer

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.util.Log

/**
 * Requests/abandons audio focus for the lifetime of one warm hub session's player —
 * matches [StreamingPcmPlayerController]'s own start()/close() granularity (one focus
 * grab for the whole session, not one per turn/utterance), since a free-form-mode
 * session can speak many separate replies and there is no reason to hand focus back to
 * another app between them (priority 22.08 п.2/п.6 "audio focus for session duration").
 *
 * [onStop]/[onDuck]/[onResume] map 1:1 onto [AudioFocusPolicy.actionFor] and are called
 * on whatever thread `AudioManager` invokes the focus-change listener on (main, in
 * practice) — same assumption [StreamingPcmPlayerController] already makes about being
 * called only from the Pigeon main thread.
 */
class AudioFocusCoordinator(
    context: Context,
    private val onStop: () -> Unit,
    private val onDuck: () -> Unit,
    private val onResume: () -> Unit,
) {
    companion object {
        private const val TAG = "AudioFocusCoordinator"
    }

    private val audioManager = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var activeRequest: AudioFocusRequest? = null

    private val listener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (AudioFocusPolicy.actionFor(focusChange)) {
            AudioFocusAction.STOP -> onStop()
            AudioFocusAction.DUCK -> onDuck()
            AudioFocusAction.RESUME -> onResume()
            AudioFocusAction.IGNORE -> {}
        }
    }

    /**
     * Best-effort: a denied request is logged, not fatal — playback proceeds either way
     * (matches [PhoneMicForegroundService.start]'s non-fatal-rejection discipline for the
     * mic side). Idempotent: replaces any still-active request from a prior session
     * rather than stacking requests.
     */
    fun request() {
        abandon()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener(listener)
            .build()
        val result = audioManager.requestAudioFocus(req)
        if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            activeRequest = req
        } else {
            Log.w(TAG, "requestAudioFocus denied ($result); continuing without it")
        }
    }

    /** Idempotent. Safe to call when [request] was never called or already abandoned. */
    fun abandon() {
        val req = activeRequest ?: return
        activeRequest = null
        try {
            audioManager.abandonAudioFocusRequest(req)
        } catch (e: Exception) {
            Log.w(TAG, "abandonAudioFocusRequest failed: ${e.message}")
        }
    }
}
