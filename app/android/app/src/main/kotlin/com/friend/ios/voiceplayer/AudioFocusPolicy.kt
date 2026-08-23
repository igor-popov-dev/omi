package com.friend.ios.voiceplayer

import android.media.AudioManager

/** What [AudioFocusCoordinator] should do about one `onAudioFocusChange` callback. */
enum class AudioFocusAction { RESUME, DUCK, STOP, IGNORE }

/**
 * Pure decision layer for `AudioManager.OnAudioFocusChangeListener` — plain-JUnit
 * testable (same discipline as `CustomSttRawAudioPolicy`): the `AudioManager.AUDIOFOCUS_*`
 * fields referenced below are `public static final int` constants, inlined by javac at
 * compile time, so this file needs no device/Robolectric to test despite the import.
 *
 * LOSS and LOSS_TRANSIENT are both mapped to STOP rather than pause-and-resume: a
 * transient loss (e.g. a ringing phone call) would need buffered turn state to resume
 * correctly, which nothing in this hub currently keeps once a turn has moved on — see
 * `AudioFocusCoordinator`'s doc for why "stop cleanly, let the user restart the mode" is
 * the deliberate choice here instead of a half-built resume path.
 */
object AudioFocusPolicy {
    fun actionFor(focusChange: Int): AudioFocusAction = when (focusChange) {
        AudioManager.AUDIOFOCUS_GAIN -> AudioFocusAction.RESUME
        AudioManager.AUDIOFOCUS_LOSS,
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> AudioFocusAction.STOP
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> AudioFocusAction.DUCK
        else -> AudioFocusAction.IGNORE
    }
}
