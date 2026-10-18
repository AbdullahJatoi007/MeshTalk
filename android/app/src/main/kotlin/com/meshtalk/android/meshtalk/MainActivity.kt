package com.meshtalk.android.meshtalk

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var frameSink: EventChannel.EventSink? = null
    private var callAudio: CallAudio? = null
    private var voice: VoiceNotes? = null
    private var bleSink: EventChannel.EventSink? = null
    private var ble: BitchatBle? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MeshNotifications.ensureChannels(this)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val ch = MethodChannel(messenger, "meshtalk/native")
        channel = ch

        val notes = VoiceNotes(
            this,
            onLimitReached = { channel?.invokeMethod("recLimit", null) },
            onPlaybackDone = { path -> channel?.invokeMethod("playDone", path) },
        )
        voice = notes

        // Microphone frames of a live call -> Dart.
        EventChannel(messenger, "meshtalk/call_frames").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    frameSink = events
                }

                override fun onCancel(arguments: Any?) {
                    frameSink = null
                }
            }
        )

        // bitchat-compatible Bluetooth LE links -> Dart.
        EventChannel(messenger, "meshtalk/ble_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    bleSink = events
                }

                override fun onCancel(arguments: Any?) {
                    bleSink = null
                }
            }
        )

        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)

                    "filesDir" -> result.success(filesDir.absolutePath)

                    // ── foreground service ───────────────────────────────
                    "startService" -> {
                        val i = Intent(this, MeshForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(i)
                        } else {
                            startService(i)
                        }
                        result.success(null)
                    }

                    "updateService" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (MeshForegroundService.running) {
                            startService(
                                Intent(this, MeshForegroundService::class.java)
                                    .putExtra(MeshForegroundService.EXTRA_TEXT, text)
                            )
                        }
                        result.success(null)
                    }

                    "serviceMic" -> {
                        // Adds/removes the "microphone" type so a call keeps
                        // its audio when the screen turns off.
                        val on = call.argument<Boolean>("on") ?: false
                        if (MeshForegroundService.running) {
                            startService(
                                Intent(this, MeshForegroundService::class.java)
                                    .putExtra(MeshForegroundService.EXTRA_MIC, on)
                            )
                        }
                        result.success(null)
                    }

                    "stopService" -> {
                        stopService(Intent(this, MeshForegroundService::class.java))
                        result.success(null)
                    }

                    "notify" -> {
                        MeshNotifications.message(
                            this,
                            call.argument<String>("title") ?: "MeshTalk",
                            call.argument<String>("body") ?: "",
                            call.argument<Boolean>("urgent") ?: false,
                        )
                        result.success(null)
                    }

                    // ── voice messages ───────────────────────────────────
                    "recStart" -> {
                        val path = call.argument<String>("path")
                        val maxMs = call.argument<Int>("maxMs") ?: 10000
                        result.success(path != null && notes.startRecording(path, maxMs))
                    }

                    "recStop" -> result.success(notes.stopRecording())

                    "recCancel" -> {
                        notes.cancelRecording()
                        result.success(null)
                    }

                    "play" -> {
                        val path = call.argument<String>("path")
                        result.success(path != null && notes.play(path))
                    }

                    "stopPlay" -> {
                        notes.stopPlayback()
                        result.success(null)
                    }

                    // ── live calls ───────────────────────────────────────
                    "callStart" -> {
                        val speaker = call.argument<Boolean>("speaker") ?: false
                        notes.stopPlayback()
                        val audio = callAudio ?: CallAudio(this) { frame ->
                            frameSink?.success(frame)
                        }.also { callAudio = it }
                        result.success(audio.start(speaker))
                    }

                    "callPlay" -> {
                        call.argument<ByteArray>("data")?.let { callAudio?.play(it) }
                        result.success(null)
                    }

                    "callMute" -> {
                        callAudio?.muted = call.argument<Boolean>("on") ?: false
                        result.success(null)
                    }

                    "callSpeaker" -> {
                        callAudio?.setSpeaker(call.argument<Boolean>("on") ?: false)
                        result.success(null)
                    }

                    "callStop" -> {
                        callAudio?.stop()
                        callAudio = null
                        result.success(null)
                    }

                    // ── bitchat Bluetooth LE ─────────────────────────────
                    "bleStart" -> {
                        val b = ble ?: BitchatBle(this) { event -> bleSink?.success(event) }
                            .also { ble = it }
                        b.start()
                        result.success(null)
                    }

                    "bleStop" -> {
                        ble?.stop()
                        result.success(null)
                    }

                    "bleSend" -> {
                        val link = call.argument<String>("link")
                        val data = call.argument<ByteArray>("data")
                        result.success(link != null && data != null && (ble?.send(link, data) ?: false))
                    }

                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("native_error", e.message, null)
            }
        }
    }

    override fun onDestroy() {
        ble?.stop()
        ble = null
        callAudio?.stop()
        callAudio = null
        voice?.release()
        super.onDestroy()
    }
}
