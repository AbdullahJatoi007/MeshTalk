package com.meshtalk.android.meshtalk

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Live call audio: microphone -> ADPCM frames (to Dart, which sends them to
 * the direct neighbour) and incoming frames -> speaker.
 *
 *  - 8 kHz mono, 100 ms frames (800 samples -> 403 bytes, ~32 kbps)
 *  - VOICE_COMMUNICATION source + echo canceller / noise suppressor when
 *    the phone has them, so the other side doesn't hear itself
 *  - small jitter buffer: playback starts once 2 frames are queued, and
 *    old frames are dropped if more than ~600 ms pile up (keeps delay low)
 */
class CallAudio(
    private val ctx: Context,
    private val onFrame: (ByteArray) -> Unit,
) {
    companion object {
        const val RATE = 8000
        const val FRAME = 800 // 100 ms
        private const val MAX_QUEUED = 6
    }

    @Volatile private var running = false
    @Volatile var muted = false

    private var recorder: AudioRecord? = null
    private var track: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var recThread: Thread? = null
    private var playThread: Thread? = null
    private val playQueue = LinkedBlockingQueue<ShortArray>()
    private val main = Handler(Looper.getMainLooper())
    private val encoder = AdpcmCodec.Encoder()
    private val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** Needs RECORD_AUDIO (checked on the Dart side first). */
    @SuppressLint("MissingPermission")
    fun start(speaker: Boolean): Boolean {
        if (running) return true
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        setSpeaker(speaker)

        val minIn = AudioRecord.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minIn, FRAME * 4),
            )
        } catch (e: Exception) {
            null
        }
        if (rec == null || rec.state != AudioRecord.STATE_INITIALIZED) {
            rec?.release()
            audio.mode = AudioManager.MODE_NORMAL
            return false
        }
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(rec.audioSessionId)?.apply { enabled = true }
        }
        if (NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
        }

        val minOut = AudioTrack.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val trk = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
            AudioFormat.Builder()
                .setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build(),
            maxOf(minOut, FRAME * 4),
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )

        recorder = rec
        track = trk
        playQueue.clear()
        running = true
        rec.startRecording()
        trk.play()
        recThread = Thread({ recordLoop() }, "call-mic").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        playThread = Thread({ playLoop() }, "call-speaker").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        return true
    }

    private fun recordLoop() {
        val buf = ShortArray(FRAME)
        while (running) {
            var read = 0
            while (read < FRAME && running) {
                val r = recorder?.read(buf, read, FRAME - read) ?: -1
                if (r <= 0) break
                read += r
            }
            if (!running) break
            if (read < FRAME) {
                // Mic hiccup: wait a little instead of spinning.
                try { Thread.sleep(20) } catch (e: InterruptedException) { break }
                continue
            }
            if (muted) java.util.Arrays.fill(buf, 0.toShort())
            val frame = encoder.encode(buf, FRAME)
            main.post { if (running) onFrame(frame) }
        }
    }

    private fun playLoop() {
        var primed = false
        while (running) {
            try {
                if (!primed) {
                    if (playQueue.size >= 2) primed = true else {
                        Thread.sleep(10)
                        continue
                    }
                }
                val pcm = playQueue.poll(300, TimeUnit.MILLISECONDS)
                if (pcm == null) {
                    primed = false // underrun: re-buffer before playing again
                    continue
                }
                track?.write(pcm, 0, pcm.size)
            } catch (e: InterruptedException) {
                break
            } catch (e: IllegalStateException) {
                break
            }
        }
    }

    /** An ADPCM frame from the other phone. */
    fun play(frame: ByteArray) {
        if (!running) return
        val pcm = AdpcmCodec.decode(frame) ?: return
        while (playQueue.size >= MAX_QUEUED) playQueue.poll()
        playQueue.offer(pcm)
    }

    @Suppress("DEPRECATION")
    fun setSpeaker(on: Boolean) {
        audio.isSpeakerphoneOn = on
    }

    fun stop() {
        if (!running && recorder == null) return
        running = false
        recThread?.interrupt()
        playThread?.interrupt()
        try { recThread?.join(500) } catch (e: InterruptedException) {}
        try { playThread?.join(500) } catch (e: InterruptedException) {}
        try { recorder?.stop() } catch (e: Exception) {}
        recorder?.release()
        try { track?.stop() } catch (e: Exception) {}
        track?.release()
        aec?.release()
        ns?.release()
        recorder = null
        track = null
        aec = null
        ns = null
        playQueue.clear()
        setSpeaker(false)
        audio.mode = AudioManager.MODE_NORMAL
    }
}
