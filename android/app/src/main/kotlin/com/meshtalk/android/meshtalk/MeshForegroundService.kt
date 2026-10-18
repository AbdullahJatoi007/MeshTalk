package com.meshtalk.android.meshtalk

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the app process alive while MeshTalk is in the background, so the
 * Flutter side keeps relaying mesh traffic. Android 8+ kills background
 * work within minutes otherwise.
 *
 * Types:
 *  - connectedDevice (always): talking to nearby phones over Bluetooth / Wi-Fi
 *  - microphone (only during a call): keeps call audio running with the
 *    screen off. Android only allows adding it while the app is on screen,
 *    which is when a call is started or answered.
 */
class MeshForegroundService : Service() {

    companion object {
        const val EXTRA_TEXT = "text"
        const val EXTRA_MIC = "mic"
        const val EXTRA_LOCATION = "location"
        const val NOTIFICATION_ID = 1001

        @Volatile
        var running = false

        @Volatile
        private var micActive = false

        @Volatile
        private var locationActive = false

        @Volatile
        private var lastText = "Relaying messages for people nearby"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(EXTRA_TEXT)?.let { lastText = it }
        if (intent?.hasExtra(EXTRA_MIC) == true) {
            micActive = intent.getBooleanExtra(EXTRA_MIC, false)
        }
        if (intent?.hasExtra(EXTRA_LOCATION) == true) {
            locationActive = intent.getBooleanExtra(EXTRA_LOCATION, false)
        }
        val prefix = when {
            micActive -> "Call in progress · "
            locationActive -> "Sharing SOS location · "
            else -> ""
        }
        val notification = MeshNotifications.ongoing(this, prefix + lastText)

        // Try the requested types, then drop the optional ones one by one if
        // Android refuses them (e.g. a permission is missing).
        if (tryForeground(notification, micActive, locationActive)) {
            running = true
        } else if (locationActive && tryForeground(notification, micActive, false)) {
            locationActive = false
            running = true
        } else if (micActive && tryForeground(notification, false, false)) {
            micActive = false
            locationActive = false
            running = true
        } else {
            // e.g. started from the background on Android 12+. The mesh still
            // works while the app is open.
            running = false
            stopSelf()
        }
        // Not sticky: without the Flutter UI there is nothing to restart.
        return START_NOT_STICKY
    }

    private fun tryForeground(notification: android.app.Notification, mic: Boolean, loc: Boolean): Boolean =
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                if (mic && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                if (loc) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                }
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            false
        }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // App swiped away from recents: the Flutter engine is gone, so stop.
        running = false
        micActive = false
        locationActive = false
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        micActive = false
        locationActive = false
        super.onDestroy()
    }
}
