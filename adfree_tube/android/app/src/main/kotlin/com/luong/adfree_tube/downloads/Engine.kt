package com.luong.adfree_tube.downloads

import android.content.Context
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Copied from YTDownloaderAndroid's Engine.kt.
 *
 * Sets up the yt-dlp, Python and ffmpeg files bundled by youtubedl-android.
 * The first launch unpacks them, which takes a few seconds.
 *
 * The bundled yt-dlp goes stale quickly and YouTube then answers with HTTP 403,
 * so setup also updates yt-dlp once a day. Updates use the nightly channel, which gets
 * YouTube fixes days before a stable release (yt-dlp itself recommends it).
 */
object Engine {
    sealed interface State {
        data object Loading : State
        data class Ready(val version: String?) : State
        data class Failed(val message: String) : State
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow<State>(State.Loading)
    val state: StateFlow<State> = _state.asStateFlow()

    /** Only one yt-dlp update may run at a time. */
    private val updateLock = Mutex()
    private const val PREFS = "engine"
    private const val LAST_AUTO_UPDATE = "lastAutoUpdate"
    private const val AUTO_UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1000L
    private val channel = YoutubeDL.UpdateChannel.NIGHTLY

    private var started = false

    /** Safe to call more than once (e.g. when the activity is recreated). */
    @Synchronized
    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        scope.launch {
            _state.value = try {
                YoutubeDL.getInstance().init(app)
                FFmpeg.getInstance().init(app)
                autoUpdate(app)
                State.Ready(YoutubeDL.getInstance().versionName(app))
            } catch (e: Exception) {
                State.Failed(e.message ?: "Could not set up yt-dlp")
            }
        }
    }

    /** Updates yt-dlp at most once a day. Being offline is fine: the current version is kept. */
    private suspend fun autoUpdate(app: Context) {
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        if (now - prefs.getLong(LAST_AUTO_UPDATE, 0L) < AUTO_UPDATE_INTERVAL_MS) return
        try {
            updateLock.withLock { YoutubeDL.getInstance().updateYoutubeDL(app, channel) }
            prefs.edit().putLong(LAST_AUTO_UPDATE, now).apply()
        } catch (e: Exception) {
            // Try again on the next launch.
        }
    }

    /** Used when YouTube blocks a download. Returns true if a newer yt-dlp was installed. */
    suspend fun updateNow(context: Context): Boolean = withContext(Dispatchers.IO) {
        val app = context.applicationContext
        try {
            val status = updateLock.withLock { YoutubeDL.getInstance().updateYoutubeDL(app, channel) }
            _state.value = State.Ready(YoutubeDL.getInstance().versionName(app))
            status == YoutubeDL.UpdateStatus.DONE
        } catch (e: Exception) {
            false
        }
    }

    /** Waits for setup to finish. Returns false if it failed. */
    suspend fun awaitReady(): Boolean = state.first { it !is State.Loading } is State.Ready

    /**
     * Downloads the newest yt-dlp. Run this when YouTube downloads start failing.
     * Returns a short message for the user.
     */
    suspend fun updateYtDlp(context: Context): String = withContext(Dispatchers.IO) {
        val app = context.applicationContext
        if (!awaitReady()) return@withContext "yt-dlp is not set up, so it can't be updated."
        try {
            val status = updateLock.withLock { YoutubeDL.getInstance().updateYoutubeDL(app, channel) }
            val version = YoutubeDL.getInstance().versionName(app)
            _state.value = State.Ready(version)
            when (status) {
                YoutubeDL.UpdateStatus.DONE -> "Updated yt-dlp to ${version ?: "the latest version"}."
                YoutubeDL.UpdateStatus.ALREADY_UP_TO_DATE -> "yt-dlp is already up to date (${version ?: "latest"})."
                else -> "yt-dlp update finished."
            }
        } catch (e: Exception) {
            "Update failed: ${e.message ?: "unknown error"}"
        }
    }
}
