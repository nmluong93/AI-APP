package com.luong.adfree_tube.downloads

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Connects the download queue to Dart (lib/downloads/android_downloader.dart).
 * Methods on "adfree_tube/downloads"; the job list, as JSON, streams on
 * "adfree_tube/downloads/jobs".
 */
class DownloadsChannel(private val context: Context, messenger: BinaryMessenger) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var streaming: Job? = null

    init {
        Engine.start(context)
        DownloadQueue.init(context)

        MethodChannel(messenger, "adfree_tube/downloads").setMethodCallHandler { call, result ->
            when (call.method) {
                "enqueue" -> {
                    val args = call.arguments as Map<*, *>
                    val id = DownloadQueue.enqueue(
                        url = args["url"] as String,
                        title = args["title"] as? String ?: "Video",
                        options = DownloadOptions.fromMap(args),
                    )
                    result.success(id)
                }
                "cancel" -> { DownloadQueue.cancel(call.idArg()); result.success(null) }
                "retry" -> { DownloadQueue.retry(call.idArg()); result.success(null) }
                "remove" -> { DownloadQueue.remove(call.idArg()); result.success(null) }
                "clearFinished" -> { DownloadQueue.clearFinished(); result.success(null) }
                "engineStatus" -> result.success(
                    when (val s = Engine.state.value) {
                        Engine.State.Loading -> "Setting up yt-dlp…"
                        is Engine.State.Ready -> "yt-dlp ${s.version ?: ""}".trim()
                        is Engine.State.Failed -> "yt-dlp failed to set up: ${s.message}"
                    }
                )
                "updateEngine" -> scope.launch { result.success(Engine.updateYtDlp(context)) }
                "open" -> {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    val intent = Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, call.argument<String>("mime"))
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        context.startActivity(intent)
                        result.success(true)
                    } catch (e: ActivityNotFoundException) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "adfree_tube/downloads/jobs").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                streaming?.cancel()
                streaming = scope.launch {
                    // StateFlow skips values a slow collector misses, so the
                    // delay keeps updates to about four per second.
                    DownloadQueue.jobs.collect { jobs ->
                        events.success(jobs.toJson())
                        delay(250)
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                streaming?.cancel()
                streaming = null
            }
        })
    }

    private fun io.flutter.plugin.common.MethodCall.idArg(): Long = (arguments as Number).toLong()
}
