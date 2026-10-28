package com.ytdownloader

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
import kotlinx.coroutines.withContext

/**
 * Sets up the yt-dlp, Python and ffmpeg files bundled by youtubedl-android.
 * The first launch unpacks them, which takes a few seconds.
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

    fun start(context: Context) {
        val app = context.applicationContext
        scope.launch {
            _state.value = try {
                YoutubeDL.getInstance().init(app)
                FFmpeg.getInstance().init(app)
                State.Ready(YoutubeDL.getInstance().versionName(app))
            } catch (e: Exception) {
                State.Failed(e.message ?: "Could not set up yt-dlp")
            }
        }
    }

    /** Waits for setup to finish. Returns false if it failed. */
    suspend fun awaitReady(): Boolean = state.first { it !is State.Loading } is State.Ready

    /**
     * Downloads the newest stable yt-dlp. Run this when YouTube downloads start failing.
     * Returns a short message for the user.
     */
    suspend fun updateYtDlp(context: Context): String = withContext(Dispatchers.IO) {
        val app = context.applicationContext
        if (!awaitReady()) return@withContext "yt-dlp is not set up, so it can't be updated."
        try {
            val status = YoutubeDL.getInstance().updateYoutubeDL(app, YoutubeDL.UpdateChannel.STABLE)
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
