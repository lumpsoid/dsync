package io.github.lumpsoid.dsync

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /**
     * `dsync/run_keep_alive`: `start` and `stop` [SyncService] for
     * `AndroidRunKeepAlive`, and `expired` back when the platform stops it.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        SyncService.onExpired = { runOnUiThread { channel.invokeMethod("expired", null) } }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> try {
                    askToNotify()
                    SyncService.start(this)
                    result.success(null)
                } catch (e: IllegalStateException) {
                    // Android 12+ refuses a start from the background; the
                    // head pauses the run instead.
                    result.error("refused", e.message, null)
                }
                "stop" -> {
                    SyncService.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Swiped away from recents, or destroyed by the system in the
     * background without finishing: either way the engine, and the head's
     * side of the run, go with this activity, so the service must not keep
     * a run nobody can see or steer. The far end's heartbeat deadline, or
     * the next dial's session claim, ends the session there.
     */
    override fun onDestroy() {
        SyncService.onExpired = null
        SyncService.stop()
        super.onDestroy()
    }

    /**
     * The run's notification needs POST_NOTIFICATIONS on Android 13+. The
     * service runs without it; only the notification is hidden. Asked once
     * per start until granted — Android itself stops showing the dialog
     * after the user declines twice.
     */
    private fun askToNotify() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
    }

    companion object {
        private const val CHANNEL = "dsync/run_keep_alive"
    }
}
