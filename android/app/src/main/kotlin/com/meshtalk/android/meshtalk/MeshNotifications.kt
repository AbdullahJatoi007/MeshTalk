package com.meshtalk.android.meshtalk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/** Notification channels + builders (no androidx dependency needed). */
object MeshNotifications {
    private const val CH_SERVICE = "mesh_service"
    private const val CH_MESSAGES = "mesh_messages"
    private const val CH_SOS = "mesh_sos"
    private var nextId = 2000

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_SERVICE, "Mesh running", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Shown while MeshTalk relays messages" }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_MESSAGES, "Messages", NotificationManager.IMPORTANCE_HIGH)
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_SOS, "SOS alerts", NotificationManager.IMPORTANCE_HIGH)
                .apply {
                    description = "Emergency broadcasts from people nearby"
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 600, 200, 600, 200, 600)
                }
        )
    }

    private fun openApp(ctx: Context): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        return PendingIntent.getActivity(ctx, 0, i, flags)
    }

    @Suppress("DEPRECATION")
    private fun builder(ctx: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, channel)
        } else {
            Notification.Builder(ctx)
        }

    fun ongoing(ctx: Context, text: String): Notification {
        ensureChannels(ctx)
        return builder(ctx, CH_SERVICE)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("MeshTalk mesh is on")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(openApp(ctx))
            .build()
    }

    @Suppress("DEPRECATION")
    fun message(ctx: Context, title: String, body: String, urgent: Boolean) {
        ensureChannels(ctx)
        val n = builder(ctx, if (urgent) CH_SOS else CH_MESSAGES)
            .setSmallIcon(
                if (urgent) android.R.drawable.stat_sys_warning
                else android.R.drawable.stat_notify_chat
            )
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(openApp(ctx))
            .apply {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    setPriority(if (urgent) Notification.PRIORITY_MAX else Notification.PRIORITY_HIGH)
                    setDefaults(Notification.DEFAULT_ALL)
                }
            }
            .build()
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(nextId++, n)
    }
}
