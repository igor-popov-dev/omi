package com.friend.ios.voiceplayer

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.LinkedBlockingQueue

/**
 * Owns one [AudioTrack] and one dedicated writer thread (the peer of
 * [com.friend.ios.phonemic.PhoneMicCaptureEngine]'s read thread, mirrored for
 * playback). Raw PCM16 chunks handed to [enqueue] are queued and written to the
 * track in order on that thread — `AudioTrack.write()` in blocking mode should
 * never run on the caller's thread, which for this class is always the Pigeon
 * main-thread call site.
 *
 * One instance per warm hub session (design doc §4/§7 step 3): a fresh instance
 * is built by the controller on every `start()`, discarded on `close()`. There is
 * no rebuild-in-place path (unlike the mic engine) because playback has no
 * interruption/route-change story to recover from — a failed write just logs and
 * the writer loop continues.
 *
 * [onStarted] fires once, off this class's writer thread, the first time real
 * audio is handed to the track (not at construction — a just-built player is
 * silent and "ready", not yet "speaking"). [onDrained] fires once per [flush]
 * after the queued-at-flush-time audio has had time to actually leave the
 * speaker; both callbacks run on the constructor-supplied [callbackHandler]
 * (the controller binds this to the main thread, matching Pigeon's FlutterApi
 * send requirement).
 */
@SuppressLint("MissingPermission") // No permission needed for playback; annotation parity with the mic engine's header comment.
class StreamingPcmPlayer(
    private val callbackHandler: Handler,
    private val onStarted: () -> Unit,
    private val onDrained: () -> Unit,
) {
    companion object {
        private const val TAG = "StreamingPcmPlayer"
        const val SAMPLE_RATE = 24000 // Gemini Live spoken-audio wire format (design doc §4/§6).

        /**
         * Drain-detection is a documented approximation, not a hardware-verified
         * one (see class doc): [flush] fires [onDrained] `bufferMs` after the
         * writer's software queue has emptied, where `bufferMs` is the
         * worst-case time the track's own hardware buffer can still be holding
         * unplayed audio. This class does not use
         * `AudioTrack.setNotificationMarkerPosition` — its behavior across a
         * `pause()`+`flush()` cycle (does the frame-position counter reset?) is
         * genuinely ambiguous across Android versions and could not be verified
         * against a real device in this environment (write access to a physical
         * phone is off-limits for this task — see lane5 rules). A marker-based
         * implementation is worth revisiting once someone can test on hardware;
         * until then this fixed post-roll is deliberately conservative (rounds
         * the buffer size up, not down) so `onDrained` errs on "slightly late",
         * never "before the audio actually finished".
         */
        private fun bufferDrainMs(bufferSizeInFrames: Int): Long =
            (bufferSizeInFrames.toLong() * 1000L) / SAMPLE_RATE + 20L
    }

    private sealed class Command {
        data class Data(val bytes: ByteArray) : Command()
        object Flush : Command()
        object Shutdown : Command()
    }

    private val queue = LinkedBlockingQueue<Command>()
    private var track: AudioTrack? = null
    private var writerThread: Thread? = null
    private val bufferSizeInFrames: Int

    @Volatile private var startedFired = false

    /** Bumped by [clear]; a pending post-roll [onDrained] runnable checks this
     *  before firing so audio discarded by a barge-in never reports "drained". */
    @Volatile private var clearEpoch: Long = 0L

    init {
        val minBuf = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuf <= 0) {
            throw IllegalStateException("AudioTrack.getMinBufferSize failed: $minBuf")
        }
        // Floor at 500ms of headroom over the HAL minimum: spoken-audio chunks
        // arrive over a WebSocket with real network jitter (unlike the mic path's
        // fixed local cadence), so a larger cushion against underrun is worth the
        // extra latency here.
        val bytesFor500ms = (SAMPLE_RATE / 2) * 2 // 2 bytes/frame (16-bit mono)
        val bufferSizeInBytes = maxOf(2 * minBuf, bytesFor500ms)
        this.bufferSizeInFrames = bufferSizeInBytes / 2

        val built = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(bufferSizeInBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        // Construction can succeed while state != INITIALIZED (bad buffer, device
        // busy) — same failure shape as AudioRecord, only checkable via getState().
        if (built.state != AudioTrack.STATE_INITIALIZED) {
            val state = built.state
            built.release()
            throw IllegalStateException("AudioTrack failed to initialize (state=$state)")
        }
        Log.i(TAG, "init: minBuf=$minBuf chosen=$bufferSizeInBytes (${bufferSizeInFrames}fr)")
        track = built
        built.play() // Arms the transport; silent until the writer feeds it real data.

        val thread = Thread({ writerLoop() }, "StreamingPcmPlayerWriter")
        writerThread = thread
        thread.start()
    }

    /** Queues raw PCM16LE mono bytes for the writer thread. Safe to call from
     *  any thread (the Pigeon main thread, in practice). */
    fun enqueue(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        queue.put(Command.Data(bytes))
    }

    /** End of turn: arms drain detection for everything queued up to this call. */
    fun flush() {
        queue.put(Command.Flush)
    }

    /**
     * Barge-in: drop everything queued and already handed to the track,
     * immediately, then leave the track paused-and-ready for the next
     * [enqueue]. Runs synchronously on the CALLER's thread (not the writer
     * queue) — this is the one operation the design doc requires to be
     * instantaneous (§6), so it cannot wait behind a backlog the writer thread
     * hasn't drained yet.
     */
    fun clear() {
        clearEpoch += 1
        queue.clear() // Cheap; drops any not-yet-written Data/Flush commands.
        val t = track ?: return
        try {
            // pause() unblocks a writer thread currently parked inside write(),
            // same idiom as PhoneMicCaptureEngine's stop()-unblocks-read().
            t.pause()
            t.flush()
            t.play() // Re-arm immediately so the barge-in replacement turn's audio can flow with no start() round trip.
        } catch (e: Exception) {
            Log.w(TAG, "clear: pause/flush/play failed: ${e.message}")
        }
    }

    /** Idempotent teardown. Safe to call more than once or before any [enqueue]. */
    fun close() {
        clearEpoch += 1 // Invalidate any in-flight post-roll drain callback.
        queue.put(Command.Shutdown)
        try {
            writerThread?.join(1000L)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        writerThread = null
        val t = track
        track = null
        try {
            t?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "close: stop() failed: ${e.message}")
        }
        try {
            t?.release()
        } catch (e: Exception) {
            Log.w(TAG, "close: release() failed: ${e.message}")
        }
    }

    private fun writerLoop() {
        while (true) {
            val command = try {
                queue.take()
            } catch (e: InterruptedException) {
                return
            }
            when (command) {
                is Command.Shutdown -> return
                is Command.Data -> writeChunk(command.bytes)
                is Command.Flush -> armDrainCallback()
            }
        }
    }

    private fun writeChunk(bytes: ByteArray) {
        val t = track ?: return
        if (!startedFired) {
            startedFired = true
            callbackHandler.post { onStarted() }
        }
        var offset = 0
        while (offset < bytes.size) {
            val n = try {
                t.write(bytes, offset, bytes.size - offset)
            } catch (e: Exception) {
                Log.e(TAG, "write() threw", e)
                return
            }
            if (n < 0) {
                Log.e(TAG, "write() returned error $n")
                return
            }
            if (n == 0) {
                // Track was paused (e.g. a clear() raced this write) — stop
                // retrying rather than busy-spin; the remaining bytes were
                // already superseded by whatever paused the track.
                return
            }
            offset += n
        }
    }

    private fun armDrainCallback() {
        val epochAtArm = clearEpoch
        val delayMs = bufferDrainMs(bufferSizeInFrames)
        callbackHandler.postDelayed({
            if (epochAtArm == clearEpoch) onDrained()
        }, delayMs)
    }
}

/** Convenience for call sites that don't already have a main-thread [Handler]. */
fun mainThreadHandler(): Handler = Handler(Looper.getMainLooper())
