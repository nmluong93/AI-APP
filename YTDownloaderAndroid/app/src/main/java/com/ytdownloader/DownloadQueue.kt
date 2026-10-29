package com.ytdownloader

import android.content.Context
import com.yausername.youtubedl_android.YoutubeDL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * The download queue. Lives as long as the app process and runs one download at a time.
 * [DownloadService] keeps the process alive (with a notification) while there is work.
 */
object DownloadQueue {
    private val _jobs = MutableStateFlow<List<DownloadJob>>(emptyList())
    val jobs: StateFlow<List<DownloadJob>> = _jobs.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private var worker: Job? = null
    private var nextId = 1L
    private lateinit var appContext: Context

    /** yt-dlp process id for the job that is running, by job id. */
    private val processIds = ConcurrentHashMap<Long, String>()
    private val cancelRequested = ConcurrentHashMap.newKeySet<Long>()

    fun init(context: Context) {
        appContext = context.applicationContext
        // Leftovers from a download that was interrupted when the app was closed.
        File(appContext.cacheDir, "downloads").deleteRecursively()
    }

    val hasUnfinishedJobs: Boolean get() = _jobs.value.any { !it.state.isFinished }

    fun enqueue(entries: List<VideoEntry>, options: DownloadOptions) {
        val newJobs = synchronized(lock) { entries.map { DownloadJob(id = nextId++, entry = it, options = options) } }
        _jobs.update { it + newJobs }
        startWorker()
    }

    fun cancel(id: Long) {
        cancelRequested += id
        val job = _jobs.value.firstOrNull { it.id == id } ?: return
        if (job.state == JobState.Queued) {
            setState(id, JobState.Cancelled)
        } else {
            processIds[id]?.let { YoutubeDL.getInstance().destroyProcessById(it) }
        }
    }

    fun cancelAll() {
        _jobs.value.filter { !it.state.isFinished }.forEach { cancel(it.id) }
    }

    fun retry(id: Long) {
        cancelRequested -= id
        modify(id) { if (it.state.isFinished) it.copy(state = JobState.Queued, progress = 0f, detail = "", savedUri = null) else it }
        startWorker()
    }

    fun remove(id: Long) {
        _jobs.update { list -> list.filterNot { it.id == id && it.state.isFinished } }
    }

    fun clearFinished() {
        _jobs.update { list -> list.filterNot { it.state.isFinished } }
    }

    private fun startWorker() {
        synchronized(lock) {
            if (worker != null) return
            worker = scope.launch { runQueue() }
        }
        DownloadService.start(appContext)
    }

    private suspend fun runQueue() {
        while (true) {
            val next = synchronized(lock) {
                val job = _jobs.value.firstOrNull { it.state == JobState.Queued }
                if (job == null) worker = null
                job
            } ?: return
            run(next)
        }
    }

    private suspend fun run(job: DownloadJob) {
        val id = job.id
        cancelRequested -= id
        modify(id) { it.copy(state = JobState.Downloading, progress = 0f, detail = "Starting…") }

        if (!Engine.awaitReady()) {
            setState(id, JobState.Failed("yt-dlp could not be set up on this phone."))
            return
        }

        val workDir = File(appContext.cacheDir, "downloads/$id")
        val processId = "job-$id-${System.nanoTime()}"
        processIds[id] = processId

        try {
            try {
                download(job, workDir, processId)
            } catch (e: Exception) {
                // YouTube answers 403 when yt-dlp is out of date. Get the newest yt-dlp and try once more.
                if (id in cancelRequested || e is YoutubeDL.CanceledException || !e.isForbidden()) throw e
                modify(id) { it.copy(state = JobState.Processing("YouTube blocked the download. Updating yt-dlp…"), progress = 0f, detail = "") }
                if (!Engine.updateNow(appContext)) throw e
                if (id in cancelRequested) {
                    setState(id, JobState.Cancelled)
                    return
                }
                modify(id) { it.copy(state = JobState.Downloading, progress = 0f, detail = "Retrying…") }
                download(job, workDir, processId)
            }
            if (id in cancelRequested) {
                setState(id, JobState.Cancelled)
                return
            }

            modify(id) { it.copy(state = JobState.Processing("Saving to phone…"), detail = "") }
            val files = workDir.listFiles().orEmpty()
                .filter { it.isFile && it.extension.lowercase() in finalExtensions }
                .sortedByDescending { it.length() }
            if (files.isEmpty()) {
                setState(id, JobState.Failed("yt-dlp finished but no file was produced."))
                return
            }
            // The finished file is the largest one; anything else is a leftover such as a cover image.
            val saved = MediaStoreSaver.save(appContext, files.first(), job.options)
            modify(id) {
                it.copy(
                    state = JobState.Done,
                    progress = 1f,
                    detail = saved.displayPath,
                    savedUri = saved.uri,
                    savedMime = saved.mime,
                )
            }
        } catch (e: YoutubeDL.CanceledException) {
            setState(id, JobState.Cancelled)
        } catch (e: Exception) {
            if (id in cancelRequested) {
                setState(id, JobState.Cancelled)
            } else {
                val message = if (e.isForbidden()) {
                    "YouTube refused the download (HTTP 403). Try again later, or tap ⋮ → Update yt-dlp and retry."
                } else {
                    YtDlp.cleanError(e.message, "Download failed.")
                }
                setState(id, JobState.Failed(message))
            }
        } finally {
            processIds.remove(id)
            workDir.deleteRecursively()
        }
    }

    /** Runs yt-dlp for one job in a fresh [workDir]. Throws if yt-dlp fails. */
    private fun download(job: DownloadJob, workDir: File, processId: String) {
        workDir.deleteRecursively()
        workDir.mkdirs()
        val progress = ProgressParser(job.options.kind)
        val request = YtDlp.downloadRequest(job.entry, job.options, workDir)
        YoutubeDL.getInstance().execute(request, processId) { _, _, line ->
            progress.handle(line)?.let { update -> modify(job.id) { update(it) } }
        }
    }

    private fun Exception.isForbidden() = message.orEmpty().contains("HTTP Error 403")

    private fun setState(id: Long, state: JobState) =
        modify(id) { it.copy(state = state, detail = if (state is JobState.Cancelled) "" else it.detail) }

    private fun modify(id: Long, change: (DownloadJob) -> DownloadJob) {
        _jobs.update { list -> list.map { if (it.id == id) change(it) else it } }
    }

    private val finalExtensions = setOf("mp4", "mp3", "m4a", "webm", "mkv", "opus", "ogg")
}

/** Reads yt-dlp's progress lines (see the templates in [YtDlp.downloadRequest]) for one job. */
private class ProgressParser(private val kind: MediaKind) {
    private var pass = 0
    private var last = 0f

    /** Returns how to change the job for this line, or null if the line isn't interesting. */
    fun handle(line: String): ((DownloadJob) -> DownloadJob)? {
        val text = line.trim()
        return when {
            text.startsWith("PROG|") -> {
                val parts = text.split("|").map { it.trim() }
                if (parts.size < 5) return null
                val (_, status, percent, speed, eta) = parts
                if (status == "finished") {
                    last = 1f
                    return { it.copy(state = JobState.Downloading, progress = 1f, detail = "Finishing…") }
                }
                val value = percent.removeSuffix("%").toFloatOrNull()?.div(100f)
                if (value != null) {
                    // A video download is two passes (video, then audio), so dropping back to 0 is expected.
                    if (value < last - 0.5f) pass += 1
                    last = value.coerceIn(0f, 1f)
                }
                val bits = mutableListOf(percent)
                if (speed.isUsable()) bits += speed
                if (eta.isUsable()) bits += "ETA $eta"
                if (kind == MediaKind.VIDEO) bits.add(0, if (pass == 0) "Video" else "Audio")
                val p = last
                val detail = bits.joinToString(" · ")
                return { it.copy(state = JobState.Downloading, progress = p, detail = detail) }
            }
            text.startsWith("PP|") -> {
                val name = text.split("|").getOrNull(2)?.trim().orEmpty()
                val label = describe(name)
                return { it.copy(state = JobState.Processing(label), detail = "") }
            }
            else -> null
        }
    }

    private fun String.isUsable() = isNotEmpty() && this != "NA" && !startsWith("Unknown")

    private fun describe(postprocessor: String) = when (postprocessor) {
        "Merger" -> "Merging video and audio…"
        "ExtractAudio" -> "Converting to MP3…"
        "EmbedThumbnail" -> "Adding cover art…"
        "FFmpegMetadata", "Metadata" -> "Writing tags…"
        "MoveFiles" -> "Moving file…"
        else -> "Processing…"
    }
}
