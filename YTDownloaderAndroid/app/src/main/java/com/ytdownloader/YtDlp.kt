package com.ytdownloader

import android.net.Uri
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

class YtDlpException(message: String) : Exception(message)

object YtDlp {
    const val SEARCH_PAGE_SIZE = 20

    private val linkPattern = Regex("""https?://\S+""")

    fun isValidLink(text: String): Boolean {
        val uri = Uri.parse(text.trim())
        val scheme = uri.scheme?.lowercase()
        return (scheme == "http" || scheme == "https") && !uri.host.isNullOrEmpty()
    }

    /** Pulls the first link out of text shared from another app (it may include a title too). */
    fun extractLink(text: String): String? = linkPattern.find(text)?.value?.trimEnd('.', ',', ')')

    /** Reads the title and the list of videos for a video or playlist link without downloading. */
    suspend fun fetchInfo(link: String): FetchedMedia = withContext(Dispatchers.IO) {
        val trimmed = link.trim()
        if (!isValidLink(trimmed)) throw YtDlpException("Please paste a link that starts with http:// or https://")
        if (!Engine.awaitReady()) throw YtDlpException("yt-dlp could not be set up on this phone.")

        val request = YoutubeDLRequest(trimmed)
            .addOption("-J")
            .addOption("--flat-playlist")
            .addOption("--no-warnings")
            .addOption("--color", "never")
        val response = try {
            YoutubeDL.getInstance().execute(request)
        } catch (e: Exception) {
            throw YtDlpException(cleanError(e.message, "yt-dlp could not read this link."))
        }
        val json = try {
            JSONObject(response.out)
        } catch (e: Exception) {
            throw YtDlpException("Unexpected response from yt-dlp.")
        }
        parse(json, trimmed)
    }

    /** Searches YouTube with yt-dlp's ytsearch, so no API key is needed. */
    suspend fun search(query: String, count: Int = SEARCH_PAGE_SIZE): List<SearchResult> = withContext(Dispatchers.IO) {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) throw YtDlpException("Type something to search for.")
        if (!Engine.awaitReady()) throw YtDlpException("yt-dlp could not be set up on this phone.")

        val request = YoutubeDLRequest("ytsearch$count:$trimmed")
            .addOption("-J")
            .addOption("--flat-playlist")
            .addOption("--no-warnings")
            .addOption("--color", "never")
        val response = try {
            YoutubeDL.getInstance().execute(request)
        } catch (e: Exception) {
            throw YtDlpException(cleanError(e.message, "yt-dlp could not search YouTube."))
        }
        val json = try {
            JSONObject(response.out)
        } catch (e: Exception) {
            throw YtDlpException("Unexpected response from yt-dlp.")
        }
        parseSearch(json)
    }

    fun parseSearch(json: JSONObject): List<SearchResult> {
        val raw = json.optJSONArray("entries") ?: return emptyList()
        val results = mutableListOf<SearchResult>()
        val seen = mutableSetOf<String>()
        for (offset in 0 until raw.length()) {
            val e = raw.optJSONObject(offset) ?: continue
            val id = e.str("id") ?: continue
            // Search can return channels or playlists too; only videos have an 11-character id.
            if (id.length != 11 || !seen.add(id)) continue
            results += SearchResult(
                id = id,
                title = e.str("title") ?: id,
                channel = e.str("channel") ?: e.str("uploader"),
                duration = e.optDouble("duration").takeUnless { it.isNaN() },
                url = "https://www.youtube.com/watch?v=$id",
                thumbnailUrl = "https://i.ytimg.com/vi/$id/mqdefault.jpg",
            )
        }
        return results
    }

    fun parse(json: JSONObject, originalLink: String): FetchedMedia {
        val title = json.str("title") ?: "Untitled"
        if (json.str("_type") == "playlist") {
            val raw = json.optJSONArray("entries")
            val entries = mutableListOf<VideoEntry>()
            if (raw != null) {
                for (offset in 0 until raw.length()) {
                    val e = raw.optJSONObject(offset) ?: continue
                    val id = e.str("id") ?: continue
                    val entryTitle = e.str("title") ?: id
                    val unavailable = entryTitle == "[Private video]" || entryTitle == "[Deleted video]"
                    entries += VideoEntry(
                        id = "$offset-$id",
                        title = entryTitle,
                        duration = e.optDouble("duration").takeUnless { it.isNaN() },
                        url = e.str("url") ?: "https://www.youtube.com/watch?v=$id",
                        playlistIndex = e.optInt("playlist_index", offset + 1),
                        isAvailable = !unavailable,
                        isSelected = !unavailable,
                    )
                }
            }
            return FetchedMedia(title, isPlaylist = true, entries = entries)
        }

        val entry = VideoEntry(
            id = json.str("id") ?: originalLink,
            title = title,
            duration = json.optDouble("duration").takeUnless { it.isNaN() },
            url = json.str("webpage_url") ?: originalLink,
            playlistIndex = null,
            isAvailable = true,
            isSelected = true,
        )
        return FetchedMedia(title, isPlaylist = false, entries = listOf(entry))
    }

    /** Builds the yt-dlp command for one video. Files are written to [outputDir] and copied to shared storage later. */
    fun downloadRequest(entry: VideoEntry, options: DownloadOptions, outputDir: File): YoutubeDLRequest {
        val request = YoutubeDLRequest(entry.url)
            .addOption("--newline")
            .addOption("--no-playlist")
            .addOption("--color", "never")
            .addOption("--no-mtime")
            .addOption("--windows-filenames")
            .addOption("--progress")
            .addOption(
                "--progress-template",
                "download:PROG|%(progress.status)s|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            )
            .addOption("--progress-template", "postprocess:PP|%(progress.status)s|%(progress.postprocessor)s")
            .addOption("-P", outputDir.absolutePath)

        var name = "%(title).150B.%(ext)s"
        if (options.numberFiles && entry.playlistIndex != null) {
            name = "%03d - ".format(entry.playlistIndex) + name
        }
        request.addOption("-o", name)

        when (options.kind) {
            MediaKind.VIDEO -> {
                val sort = buildList {
                    options.videoQuality.maxHeight?.let { add("res:$it") }
                    if (options.preferH264) add("vcodec:h264")
                    add("ext:mp4:m4a")
                }
                request.addOption("-f", "bv*+ba/b")
                    .addOption("-S", sort.joinToString(","))
                    .addOption("--merge-output-format", "mp4")
                    .addOption("--embed-metadata")
            }
            MediaKind.AUDIO -> {
                request.addOption("-f", "ba/b")
                    .addOption("-x")
                    .addOption("--audio-format", "mp3")
                    .addOption("--audio-quality", "${options.audioKbps}K")
                    .addOption("--embed-metadata")
                    .addOption("--embed-thumbnail")
            }
        }
        return request
    }

    /** Turns yt-dlp's stderr into one readable line. */
    fun cleanError(raw: String?, fallback: String): String {
        val lines = raw.orEmpty().lines().map { it.trim() }.filter { it.isNotEmpty() }
        val error = lines.lastOrNull { it.startsWith("ERROR:") }?.removePrefix("ERROR:")?.trim()
        return (error ?: lines.lastOrNull() ?: fallback).take(400)
    }

    private fun JSONObject.str(name: String): String? =
        if (isNull(name)) null else optString(name).takeIf { it.isNotEmpty() }
}
