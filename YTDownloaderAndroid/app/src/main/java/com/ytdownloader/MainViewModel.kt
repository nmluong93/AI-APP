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

private const val MAX_SEARCH_RESULTS = 100

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

    var mode by pref("mode", InputMode.LINK, InputMode.entries)

    // YouTube search.
    var query by mutableStateOf("")
    var searchResults by mutableStateOf<List<SearchResult>>(emptyList())
        private set
    var isSearching by mutableStateOf(false)
        private set
    var searchError by mutableStateOf<String?>(null)
        private set
    /** True once a search finished, so an empty list means "nothing found" rather than "not searched yet". */
    var hasSearched by mutableStateOf(false)
        private set
    /** Ids of search results queued in this session, so their button can show that. */
    var queuedResultIds by mutableStateOf<Set<String>>(emptySet())
        private set
    private var searchedQuery = ""
    private var requestedCount = 0

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

    private var searchJob: Job? = null
    private var searchToken = 0

    /** Runs a new search, or with [more] fetches a longer list for the same query. */
    fun search(more: Boolean = false) {
        val text = if (more) searchedQuery else query.trim()
        if (text.isEmpty() || isSearching) return
        val count = if (more) searchResults.size + YtDlp.SEARCH_PAGE_SIZE else YtDlp.SEARCH_PAGE_SIZE
        searchJob?.cancel()
        val token = ++searchToken
        isSearching = true
        searchError = null
        if (!more) {
            searchResults = emptyList()
            hasSearched = false
        }
        searchJob = viewModelScope.launch {
            try {
                val results = YtDlp.search(text, count)
                if (token == searchToken) {
                    searchResults = results
                    searchedQuery = text
                    requestedCount = count
                    hasSearched = true
                }
            } catch (e: YtDlpException) {
                if (token == searchToken) searchError = e.message
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (token == searchToken) searchError = e.message ?: "Something went wrong."
            } finally {
                if (token == searchToken) isSearching = false
            }
        }
    }

    /** True when the last search filled a whole page, so asking for more may find more. */
    val canLoadMore: Boolean
        get() = hasSearched && searchResults.size >= requestedCount && requestedCount < MAX_SEARCH_RESULTS

    /** Queues one search result with the current download options. */
    fun download(result: SearchResult) {
        DownloadQueue.enqueue(listOf(result.toEntry()), currentOptions(isPlaylist = false, playlistTitle = null))
        queuedResultIds = queuedResultIds + result.id
        message = "Added to downloads"
    }

    /** Called with text shared from another app, such as YouTube's Share button. */
    fun onSharedText(text: String) {
        val found = YtDlp.extractLink(text) ?: return
        mode = InputMode.LINK
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
        DownloadQueue.enqueue(entries, currentOptions(current.isPlaylist, current.title))
        message = if (entries.size == 1) "Added to downloads" else "Added ${entries.size} videos to downloads"
    }

    private fun currentOptions(isPlaylist: Boolean, playlistTitle: String?) = DownloadOptions(
        kind = kind,
        videoQuality = quality,
        preferH264 = preferH264,
        audioKbps = audioKbps,
        numberFiles = isPlaylist && numberPlaylistFiles,
        subfolder = if (isPlaylist && playlistSubfolder && playlistTitle != null) sanitizedFolderName(playlistTitle) else null,
        saveLocation = saveLocation,
    )

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
