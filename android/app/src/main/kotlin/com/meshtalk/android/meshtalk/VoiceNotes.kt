package com.meshtalk.android.meshtalk

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import java.io.File

/**
 * Records voice messages (AAC in .m4a, mono 16 kHz at 16 kbps: about
 * 2 KB per second, so 10 s ≈ 20 KB) and plays them back.
 */
class VoiceNotes(
    private val ctx: Context,
    private val onLimitReached: () -> Unit,
    private val onPlaybackDone: (String) -> Unit,
) {
    private var recorder: MediaRecorder? = null
    private var recPath: String? = null
    private var recStartedAt = 0L
    private var player: MediaPlayer? = null

    /** Needs RECORD_AUDIO (checked on the Dart side first). */
    fun startRecording(path: String, maxMs: Int): Boolean {
        stopPlayback()
        cancelRecording()
        return try {
            File(path).parentFile?.mkdirs()
            val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(ctx)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(16000)
            r.setAudioEncodingBitRate(16000)
            r.setMaxDuration(maxMs)
            r.setOutputFile(path)
            r.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) {
                    onLimitReached()
                }
            }
            r.prepare()
            r.start()
            recorder = r
            recPath = path
            recStartedAt = SystemClock.elapsedRealtime()
            true
        } catch (e: Exception) {
            recorder?.release()
            recorder = null
            File(path).delete()
            false
        }
    }

    /** Stops and keeps the file. Returns its length in ms, or -1 if it failed. */
    fun stopRecording(): Int {
        val r = recorder ?: return -1
        recorder = null
        val dur = (SystemClock.elapsedRealtime() - recStartedAt).toInt()
        return try {
            r.stop()
            r.release()
            dur
        } catch (e: RuntimeException) {
            // stop() throws when almost nothing was recorded.
            r.release()
            recPath?.let { File(it).delete() }
            -1
        }
    }

    fun cancelRecording() {
        val r = recorder ?: return
        recorder = null
        try { r.stop() } catch (e: Exception) {}
        r.release()
        recPath?.let { File(it).delete() }
    }

    fun play(path: String): Boolean {
        stopPlayback()
        return try {
            val p = MediaPlayer()
            p.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            p.setDataSource(path)
            p.setOnCompletionListener {
                stopPlayback()
                onPlaybackDone(path)
            }
            p.prepare()
            p.start()
            player = p
            true
        } catch (e: Exception) {
            stopPlayback()
            false
        }
    }

    fun stopPlayback() {
        val p = player ?: return
        player = null
        try { p.stop() } catch (e: Exception) {}
        p.release()
    }

    fun release() {
        cancelRecording()
        stopPlayback()
    }
}
