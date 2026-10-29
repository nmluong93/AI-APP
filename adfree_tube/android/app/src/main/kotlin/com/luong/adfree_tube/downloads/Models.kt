package com.luong.adfree_tube.downloads

import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject

// Download code adapted from the YT Downloader Android app in this repo
// (YTDownloaderAndroid/). It's a copy on purpose: the two apps don't depend
// on each other.

enum class MediaKind { VIDEO, AUDIO }

/** What to download, as sent from Dart. */
data class DownloadOptions(
    val kind: MediaKind,
    /** Highest video height to pick, or null for the best available. */
    val maxHeight: Int?,
    val audioKbps: Int,
) {
    companion object {
        fun fromMap(map: Map<*, *>) = DownloadOptions(
            kind = if (map["kind"] == "audio") MediaKind.AUDIO else MediaKind.VIDEO,
            maxHeight = (map["maxHeight"] as? Number)?.toInt(),
            audioKbps = (map["audioKbps"] as? Number)?.toInt() ?: 192,
        )
    }
}

sealed interface JobState {
    data object Queued : JobState
    data object Downloading : JobState
    data class Processing(val label: String) : JobState
    data object Done : JobState
    data class Failed(val message: String) : JobState
    data object Cancelled : JobState

    val isFinished: Boolean get() = this is Done || this is Failed || this is Cancelled
    val isActive: Boolean get() = this is Downloading || this is Processing
}

data class DownloadJob(
    val id: Long,
    val url: String,
    val title: String,
    val options: DownloadOptions,
    val state: JobState = JobState.Queued,
    val progress: Float = 0f,
    val detail: String = "",
    val savedUri: Uri? = null,
    val savedMime: String? = null,
    val savedPath: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("url", url)
        put("title", title)
        put("kind", if (options.kind == MediaKind.AUDIO) "audio" else "video")
        put("state", when (state) {
            JobState.Queued -> "queued"
            JobState.Downloading -> "downloading"
            is JobState.Processing -> "processing"
            JobState.Done -> "done"
            is JobState.Failed -> "failed"
            JobState.Cancelled -> "cancelled"
        })
        put("progress", progress.toDouble())
        put("detail", when (state) {
            is JobState.Processing -> state.label
            is JobState.Failed -> state.message
            else -> detail
        })
        savedUri?.let { put("savedUri", it.toString()) }
        savedMime?.let { put("savedMime", it) }
        savedPath?.let { put("savedPath", it) }
    }
}

fun List<DownloadJob>.toJson(): String = JSONArray().also { array -> forEach { array.put(it.toJson()) } }.toString()
