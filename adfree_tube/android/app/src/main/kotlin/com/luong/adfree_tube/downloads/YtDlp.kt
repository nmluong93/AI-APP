package com.luong.adfree_tube.downloads

import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File

/** Builds yt-dlp commands. Adapted from YTDownloaderAndroid's YtDlp.kt. */
object YtDlp {
    /** Builds the yt-dlp command for one video. Files are written to [outputDir] and copied to shared storage later. */
    fun downloadRequest(url: String, options: DownloadOptions, outputDir: File): YoutubeDLRequest {
        val request = YoutubeDLRequest(url)
        for (option in arguments(options, outputDir.absolutePath)) {
            if (option.size == 1) request.addOption(option[0]) else request.addOption(option[0], option[1])
        }
        return request
    }

    /**
     * The options, as [name] or [name, value] pairs. The same list is built in Dart for the
     * Mac version (lib/downloads/yt_dlp_args.dart); keep the two in step.
     */
    fun arguments(options: DownloadOptions, outputDir: String): List<List<String>> = buildList {
        add(listOf("--newline"))
        add(listOf("--no-playlist"))
        add(listOf("--color", "never"))
        add(listOf("--no-mtime"))
        add(listOf("--windows-filenames"))
        add(listOf("--progress"))
        add(listOf("--progress-template",
            "download:PROG|%(progress.status)s|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"))
        add(listOf("--progress-template", "postprocess:PP|%(progress.status)s|%(progress.postprocessor)s"))
        add(listOf("-P", outputDir))
        add(listOf("-o", "%(title).150B.%(ext)s"))
        when (options.kind) {
            MediaKind.VIDEO -> {
                val sort = buildList {
                    options.maxHeight?.let { add("res:$it") }
                    add("vcodec:h264")
                    add("ext:mp4:m4a")
                }
                add(listOf("-f", "bv*+ba/b"))
                add(listOf("-S", sort.joinToString(",")))
                add(listOf("--merge-output-format", "mp4"))
                add(listOf("--embed-metadata"))
            }
            MediaKind.AUDIO -> {
                add(listOf("-f", "ba/b"))
                add(listOf("-x"))
                add(listOf("--audio-format", "mp3"))
                add(listOf("--audio-quality", "${options.audioKbps}K"))
                add(listOf("--embed-metadata"))
                add(listOf("--embed-thumbnail"))
            }
        }
    }

    /** Turns yt-dlp's stderr into one readable line. */
    fun cleanError(raw: String?, fallback: String): String {
        val lines = raw.orEmpty().lines().map { it.trim() }.filter { it.isNotEmpty() }
        val error = lines.lastOrNull { it.startsWith("ERROR:") }?.removePrefix("ERROR:")?.trim()
        return (error ?: lines.lastOrNull() ?: fallback).take(400)
    }
}
