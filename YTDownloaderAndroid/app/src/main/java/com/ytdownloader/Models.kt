package com.ytdownloader

import android.net.Uri

enum class MediaKind(val title: String) {
    VIDEO("Video (MP4)"),
    AUDIO("Audio (MP3)"),
}

enum class VideoQuality(val title: String, val maxHeight: Int?) {
    BEST("Best available", null),
    P2160("2160p (4K)", 2160),
    P1440("1440p", 1440),
    P1080("1080p", 1080),
    P720("720p", 720),
    P480("480p", 480),
    P360("360p", 360),
}

val audioBitrates = listOf(320, 256, 192, 128)

/** Where finished files are saved on the phone. */
enum class SaveLocation(val title: String, val description: String) {
    MEDIA("Movies / Music", "Videos go to Movies/YT Downloader, MP3s to Music/YT Downloader"),
    DOWNLOADS("Download", "Everything goes to Download/YT Downloader"),
}

data class VideoEntry(
    val id: String,
    val title: String,
    val duration: Double?,
    val url: String,
    /** 1-based position in the playlist, null for a single video. */
    val playlistIndex: Int?,
    val isAvailable: Boolean,
    val isSelected: Boolean,
)

data class FetchedMedia(
    val title: String,
    val isPlaylist: Boolean,
    val entries: List<VideoEntry>,
)

data class DownloadOptions(
    val kind: MediaKind,
    val videoQuality: VideoQuality,
    val preferH264: Boolean,
    val audioKbps: Int,
    val numberFiles: Boolean,
    /** Folder name inside "YT Downloader" for a playlist, or null to save directly in it. */
    val subfolder: String?,
    val saveLocation: SaveLocation,
)

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
    val entry: VideoEntry,
    val options: DownloadOptions,
    val state: JobState = JobState.Queued,
    val progress: Float = 0f,
    val detail: String = "",
    val savedUri: Uri? = null,
    val savedMime: String? = null,
)

fun formatDuration(seconds: Double?): String {
    if (seconds == null || seconds.isNaN() || seconds <= 0) return ""
    val total = Math.round(seconds).toInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

/** Makes a string safe to use as a single folder name. */
fun sanitizedFolderName(name: String): String {
    val cleaned = name.replace(Regex("[/:\\\\?%*|\"<>]"), "_")
        .trim { it.isWhitespace() || it == '.' }
    return if (cleaned.isEmpty()) "Playlist" else cleaned.take(120)
}
