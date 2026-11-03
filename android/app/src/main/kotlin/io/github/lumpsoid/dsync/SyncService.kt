package io.github.lumpsoid.dsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps a live run going with the screen off or the app in the background
 * (SPEC §11.4): a `dataSync` foreground service holding a partial wake lock,
 * so the CPU keeps running, and a Wi-Fi lock, so power save does not
 * throttle the link. Started and stopped by `RunKeepAlive` in the head over
 * [MainActivity]'s channel; it drives nothing itself — the run is the Rust
 * hub's, in this same process.
 */
class SyncService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground comes first whatever happens next: a service
        // started with startForegroundService that never calls it crashes
        // the app, and that includes one stopped before it got here.
        try {
            val notification = notification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: IllegalStateException) {
            // Refused from the background (Android 12+): the run is not
            // kept, so the head is told, as for a timeout, and pauses it.
            stopSelf()
            onExpired?.invoke()
            return START_NOT_STICKY
        }
        if (stopRequested) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = this
        acquireLocks()
        // A killed process takes the run with it: nothing to restart.
        return START_NOT_STICKY
    }

    /**
     * Android 15's cap on `dataSync` (six hours a day in the background).
     * The service must stop within seconds or the app is crashed; the head
     * is told, and pauses the run.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
        onExpired?.invoke()
    }

    override fun onDestroy() {
        if (running === this) running = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dsync:run").apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_LIMIT_MS)
            }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION") // LOW_LATENCY holds only with the screen on.
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "dsync:run").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun notification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Sync runs", NotificationManager.IMPORTANCE_LOW),
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return builder
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Sync running")
            .setContentText("dsync keeps syncing with the screen off")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "sync_run"
        private const val NOTIFICATION_ID = 1

        /** The wake lock's backstop, past Android 15's own six-hour cap. */
        private const val WAKE_LOCK_LIMIT_MS = 7 * 60 * 60 * 1000L

        /** Set by [MainActivity] while its engine is attached. */
        var onExpired: (() -> Unit)? = null

        private var running: SyncService? = null
        private var stopRequested = false

        fun start(context: Context) {
            stopRequested = false
            val service = Intent(context, SyncService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        }

        /**
         * Stops the service, or the one still starting once it has called
         * startForeground — never stopService before then, which crashes.
         */
        fun stop() {
            stopRequested = true
            running?.stopSelf()
        }
    }
}
