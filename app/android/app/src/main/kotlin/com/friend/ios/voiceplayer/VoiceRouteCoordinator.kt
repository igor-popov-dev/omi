package com.friend.ios.voiceplayer

import android.bluetooth.BluetoothProfile
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Self-host patch, not for upstream: routes one live voice-mode session through the
 * user's headset instead of the phone's own mic and speaker.
 *
 * WHY THIS EXISTS
 * ---------------
 * The capture engine opens `MediaRecorder.AudioSource.MIC`, which follows the system's
 * *media* routing. A Bluetooth headset connected for playback (A2DP) carries no mic in
 * that mode, so the assistant's reply plays into the user's ears while the user keeps
 * talking into the phone lying on the table — the exact failure reported on 23.08 ("на
 * улице колонка даёт плохой материал, при подключённой гарнитуре хочу говорить в неё").
 * Reaching a Bluetooth mic requires the *communication* route (SCO/HFP on older
 * Android, a communication device on 31+), which nothing in this app switched on
 * outside the phone-calls plugin.
 *
 * SCOPE IS DELIBERATE. This engages for the lifetime of a voice-mode session only
 * ([StreamingPcmPlayerController.start] / `close`), never for ambient capture: the
 * communication route is a system-wide mode, and holding it open all day would keep a
 * headset's mic hot and degrade music playback to call-quality audio.
 *
 * Best-effort by design, like [AudioFocusCoordinator]: every failure is logged and
 * swallowed, because a voice session that talks through the phone speaker is still a
 * working voice session, while a crash here would take the whole mode down.
 */
class VoiceRouteCoordinator(context: Context) {
    companion object {
        private const val TAG = "VoiceRouteCoordinator"

        /** Headset types worth routing to, best first: a mic the user deliberately put on. */
        private val PREFERRED_TYPES = listOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
        )
    }

    private val audioManager = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var engaged = false
    private var previousMode: Int = AudioManager.MODE_NORMAL
    private var startedSco = false

    /**
     * Switch to the communication route and, when a headset is present, pin the session
     * to it. Idempotent: a second call while engaged is a no-op rather than a second
     * mode save (which would lose the user's original mode).
     */
    fun engage() {
        if (engaged) return
        try {
            previousMode = audioManager.mode
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            engaged = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                engageModern()
            } else {
                @Suppress("DEPRECATION")
                engageLegacy()
            }
        } catch (e: Exception) {
            Log.w(TAG, "engage failed; continuing on the default route: ${e.message}")
        }
    }

    /** Idempotent. Safe when [engage] was never called or already released. */
    fun release() {
        if (!engaged) return
        engaged = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            } else if (startedSco) {
                @Suppress("DEPRECATION")
                audioManager.stopBluetoothSco()
                @Suppress("DEPRECATION")
                audioManager.isBluetoothScoOn = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "clearing the communication device failed: ${e.message}")
        }
        startedSco = false
        try {
            audioManager.mode = previousMode
        } catch (e: Exception) {
            Log.w(TAG, "restoring audio mode failed: ${e.message}")
        }
    }

    /** True when the session is currently pinned to a headset (for logging/diagnostics). */
    fun routedToHeadset(): Boolean {
        if (!engaged) return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.communicationDevice?.type in PREFERRED_TYPES
        } else {
            @Suppress("DEPRECATION")
            audioManager.isBluetoothScoOn
        }
    }

    private fun engageModern() {
        val available = audioManager.availableCommunicationDevices
        val headset = PREFERRED_TYPES.firstNotNullOfOrNull { type ->
            available.firstOrNull { it.type == type }
        }
        if (headset == null) {
            Log.i(TAG, "no headset among ${available.map { it.type }}; staying on the phone route")
            return
        }
        val ok = audioManager.setCommunicationDevice(headset)
        Log.i(TAG, "routing voice session to ${headset.productName} (type=${headset.type}) ok=$ok")
    }

    @Suppress("DEPRECATION")
    private fun engageLegacy() {
        val hasBluetoothHeadset = audioManager
            .getDevices(AudioManager.GET_DEVICES_INPUTS)
            .any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
        if (!hasBluetoothHeadset || !audioManager.isBluetoothScoAvailableOffCall) {
            Log.i(TAG, "no SCO headset available off-call; staying on the phone route")
            return
        }
        audioManager.startBluetoothSco()
        audioManager.isBluetoothScoOn = true
        startedSco = true
        Log.i(TAG, "started Bluetooth SCO for the voice session")
    }
}
