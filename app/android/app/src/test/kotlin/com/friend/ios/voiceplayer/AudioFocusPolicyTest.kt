package com.friend.ios.voiceplayer

import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Test

class AudioFocusPolicyTest {
    @Test
    fun gainMapsToResume() {
        assertEquals(AudioFocusAction.RESUME, AudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_GAIN))
    }

    @Test
    fun permanentLossMapsToStop() {
        assertEquals(AudioFocusAction.STOP, AudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_LOSS))
    }

    @Test
    fun transientLossAlsoMapsToStop() {
        // Deliberate: see AudioFocusPolicy's file doc for why a resumable pause
        // is not implemented — a transient loss is treated the same as a
        // permanent one, not left running silently.
        assertEquals(AudioFocusAction.STOP, AudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT))
    }

    @Test
    fun duckableTransientLossMapsToDuck() {
        assertEquals(
            AudioFocusAction.DUCK,
            AudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        )
    }

    @Test
    fun unknownValueIsIgnored() {
        assertEquals(AudioFocusAction.IGNORE, AudioFocusPolicy.actionFor(12345))
    }
}
