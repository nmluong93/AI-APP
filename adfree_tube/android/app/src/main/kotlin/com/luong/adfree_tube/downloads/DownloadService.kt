package com.luong.adfree_tube.downloads

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.luong.adfree_tube.MainActivity
import com.luong.adfree_tube.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Copied from YTDownloaderAndroid's DownloadService.kt.
 *
 * Keeps downloads running when the screen is off or you switch apps, and shows their progress
 * in the notification shade. It stops itself when the queue is empty.
 */
class DownloadService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var watcher: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL_ALL) {
            DownloadQueue.cancelAll()
        }
        createChannels()
        ServiceCompat.startForeground(
            this, PROGRESS_ID, buildProgress(DownloadQueue.jobs.value),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        if (watcher == null) {
            watcher = scope.launch {
                // StateFlow skips values a slow collector misses, so the delay keeps notification updates to about two per second.
                DownloadQueue.jobs.collect { jobs ->
                    if (jobs.any { !it.state.isFinished }) {
                        notificationManager().notify(PROGRESS_ID, buildProgress(jobs))
                        delay(500)
                    } else {
                        finish(jobs)
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun finish(jobs: List<DownloadJob>) {
        val done = jobs.count { it.state == JobState.Done }
        val failed = jobs.count { it.state is JobState.Failed }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        if (done + failed > 0) {
            val text = buildList {
                if (done > 0) add("$done saved")
                if (failed > 0) add("$failed failed")
            }.joinToString(", ")
            val notification = NotificationCompat.Builder(this, CHANNEL_DONE)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Downloads finished")
                .setContentText(text)
                .setContentIntent(openAppIntent())
                .setAutoCancel(true)
                .build()
            notificationManager().notify(DONE_ID, notification)
        }
        stopSelf()
    }

    private fun buildProgress(jobs: List<DownloadJob>): Notification {
        val active = jobs.firstOrNull { it.state.isActive }
        val remaining = jobs.count { !it.state.isFinished }
        val builder = NotificationCompat.Builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(openAppIntent())
            .addAction(0, "Cancel all", cancelAllIntent())
        if (active == null) {
            builder.setContentTitle("Preparing downloads…").setProgress(0, 0, true)
        } else {
            val status = when (val s = active.state) {
                is JobState.Processing -> s.label
                else -> active.detail
            }
            builder.setContentTitle(active.title)
                .setContentText(if (remaining > 1) "$status  ($remaining left)" else status)
            if (active.state is JobState.Processing) {
                builder.setProgress(0, 0, true)
            } else {
                builder.setProgress(1000, (active.progress * 1000).toInt(), false)
            }
        }
        return builder.build()
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun cancelAllIntent(): PendingIntent = PendingIntent.getService(
        this, 1,
        Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL_ALL),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun notificationManager() = getSystemService(NotificationManager::class.java)

    private fun createChannels() {
        val manager = notificationManager()
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_PROGRESS, "Download progress", NotificationManager.IMPORTANCE_LOW)
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, "Finished downloads", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    companion object {
        private const val CHANNEL_PROGRESS = "downloads_progress"
        private const val CHANNEL_DONE = "downloads_done"
        private const val PROGRESS_ID = 4101
        private const val DONE_ID = 4102
        private const val ACTION_CANCEL_ALL = "com.luong.adfree_tube.CANCEL_ALL_DOWNLOADS"

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java))
        }
    }
}
