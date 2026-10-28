package com.ytdownloader

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

class MainViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var link by mutableStateOf("")
    var media by mutableStateOf<FetchedMedia?>(null)
        private set
    var isFetching by mutableStateOf(false)
        private set
    var fetchError by mutableStateOf<String?>(null)
        private set
    var isUpdating by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null)

    // Options, remembered between launches.
    var kind by pref("kind", MediaKind.VIDEO, MediaKind.entries)
    var quality by pref("quality", VideoQuality.P1080, VideoQuality.entries)
    var saveLocation by pref("saveLocation", SaveLocation.MEDIA, SaveLocation.entries)
    var preferH264 by boolPref("preferH264", true)
    var playlistSubfolder by boolPref("playlistSubfolder", true)
    var numberPlaylistFiles by boolPref("numberPlaylistFiles", true)
    var audioKbps by mutableStateOf(prefs.getInt("audioKbps", 320))
        private set

    fun updateAudioKbps(value: Int) {
        audioKbps = value
        prefs.edit().putInt("audioKbps", value).apply()
    }

    val selectedEntries: List<VideoEntry>
        get() = media?.entries.orEmpty().filter { it.isSelected && it.isAvailable }

    private var fetchJob: Job? = null
    private var fetchToken = 0

    fun fetch(force: Boolean = false) {
        val text = link.trim()
        if (text.isEmpty() || (isFetching && !force)) return
        fetchJob?.cancel()
        val token = ++fetchToken
        isFetching = true
        fetchError = null
        media = null
        fetchJob = viewModelScope.launch {
            try {
                val result = YtDlp.fetchInfo(text)
                if (token == fetchToken) media = result
            } catch (e: YtDlpException) {
                if (token == fetchToken) fetchError = e.message
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (token == fetchToken) fetchError = e.message ?: "Something went wrong."
            } finally {
                if (token == fetchToken) isFetching = false
            }
        }
    }

    /** Called with text shared from another app, such as YouTube's Share button. */
    fun onSharedText(text: String) {
        val found = YtDlp.extractLink(text) ?: return
        link = found
        fetch(force = true)
    }

    fun toggle(entryId: String) {
        val current = media ?: return
        media = current.copy(entries = current.entries.map {
            if (it.id == entryId && it.isAvailable) it.copy(isSelected = !it.isSelected) else it
        })
    }

    fun setAllSelected(value: Boolean) {
        val current = media ?: return
        media = current.copy(entries = current.entries.map { if (it.isAvailable) it.copy(isSelected = value) else it })
    }

    fun download() {
        val current = media ?: return
        val entries = selectedEntries
        if (entries.isEmpty()) return
        val options = DownloadOptions(
            kind = kind,
            videoQuality = quality,
            preferH264 = preferH264,
            audioKbps = audioKbps,
            numberFiles = current.isPlaylist && numberPlaylistFiles,
            subfolder = if (current.isPlaylist && playlistSubfolder) sanitizedFolderName(current.title) else null,
            saveLocation = saveLocation,
        )
        DownloadQueue.enqueue(entries, options)
        message = if (entries.size == 1) "Added to downloads" else "Added ${entries.size} videos to downloads"
    }

    fun updateYtDlp() {
        if (isUpdating) return
        if (DownloadQueue.hasUnfinishedJobs) {
            message = "Wait for downloads to finish before updating yt-dlp."
            return
        }
        isUpdating = true
        viewModelScope.launch {
            message = Engine.updateYtDlp(getApplication())
            isUpdating = false
        }
    }

    private fun <T : Enum<T>> pref(key: String, default: T, all: List<T>): ReadWriteProperty<Any?, T> {
        val saved = prefs.getString(key, null)
        val state = mutableStateOf(all.firstOrNull { it.name == saved } ?: default)
        return object : ReadWriteProperty<Any?, T> {
            override fun getValue(thisRef: Any?, property: KProperty<*>): T = state.value
            override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
                state.value = value
                prefs.edit().putString(key, value.name).apply()
            }
        }
    }

    private fun boolPref(key: String, default: Boolean): ReadWriteProperty<Any?, Boolean> {
        val state = mutableStateOf(prefs.getBoolean(key, default))
        return object : ReadWriteProperty<Any?, Boolean> {
            override fun getValue(thisRef: Any?, property: KProperty<*>): Boolean = state.value
            override fun setValue(thisRef: Any?, property: KProperty<*>, value: Boolean) {
                state.value = value
                prefs.edit().putBoolean(key, value).apply()
            }
        }
    }
}
