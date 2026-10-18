package com.meshtalk.android.meshtalk

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * Position for SOS alerts, from Android's own LocationManager: GPS works
 * with no internet and no Google services. Also opens a position in the
 * phone's maps app.
 */
@SuppressLint("MissingPermission") // permission is requested in Dart first
class MeshLocation(private val ctx: Context) {

    private val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager?
    private val main = Handler(Looper.getMainLooper())

    private fun toMap(l: Location): Map<String, Any> = mapOf(
        "lat" to l.latitude,
        "lon" to l.longitude,
        "acc" to (if (l.hasAccuracy()) l.accuracy.toDouble() else 0.0),
        "ts" to l.time,
    )

    fun enabled(): Boolean = try {
        val m = lm ?: return false
        m.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            m.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    } catch (e: Exception) {
        false
    }

    /** Newest cached position from any provider, or null. Instant. */
    fun lastKnown(): Map<String, Any>? {
        val m = lm ?: return null
        var best: Location? = null
        for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
            val l = try { m.getLastKnownLocation(p) } catch (e: Exception) { null } ?: continue
            if (best == null || l.time > best.time) best = l
        }
        return best?.let { toMap(it) }
    }

    /**
     * A fresh position: returns as soon as a fix is accurate to ~30 m, or
     * the best fix seen (or the cached one) when [timeoutMs] runs out.
     */
    fun current(timeoutMs: Long, done: (Map<String, Any>?) -> Unit) {
        val m = lm
        if (m == null) {
            done(null)
            return
        }
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .filter { try { m.isProviderEnabled(it) } catch (e: Exception) { false } }
        if (providers.isEmpty()) {
            done(lastKnown())
            return
        }
        var finished = false
        var best: Location? = null

        // All four methods implemented: older Android versions have no
        // default implementations and would crash on a missing one.
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (finished) return
                val b = best
                if (b == null || (location.hasAccuracy() && location.accuracy < b.accuracy)) best = location
                if (location.hasAccuracy() && location.accuracy <= 30f) finish()
            }

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}

            fun finish() {
                if (finished) return
                finished = true
                try { m.removeUpdates(this) } catch (e: Exception) {}
                done(best?.let { toMap(it) } ?: lastKnown())
            }
        }
        for (p in providers) {
            try {
                m.requestLocationUpdates(p, 0L, 0f, listener, Looper.getMainLooper())
            } catch (e: Exception) {}
        }
        main.postDelayed({ listener.finish() }, timeoutMs)
    }

    /** Opens the position in the phone's maps app (falls back to a browser). */
    fun openMap(lat: Double, lon: Double, label: String): Boolean {
        val geo = Uri.parse("geo:$lat,$lon?q=$lat,$lon(${Uri.encode(label)})")
        val web = Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lon")
        for (uri in listOf(geo, web)) {
            try {
                ctx.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e: ActivityNotFoundException) {
                // try the next one
            } catch (e: Exception) {
                return false
            }
        }
        return false
    }
}
