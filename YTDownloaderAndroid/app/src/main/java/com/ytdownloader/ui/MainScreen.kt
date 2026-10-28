@file:OptIn(ExperimentalMaterial3Api::class)

package com.ytdownloader.ui

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.ytdownloader.DownloadJob
import com.ytdownloader.DownloadQueue
import com.ytdownloader.Engine
import com.ytdownloader.JobState
import com.ytdownloader.MainViewModel
import com.ytdownloader.MediaKind
import com.ytdownloader.SaveLocation
import com.ytdownloader.VideoEntry
import com.ytdownloader.VideoQuality
import com.ytdownloader.audioBitrates
import com.ytdownloader.formatDuration

@Composable
fun MainScreen(vm: MainViewModel) {
    val context = LocalContext.current
    val engine by Engine.state.collectAsState()
    val jobs by DownloadQueue.jobs.collectAsState()
    val snackbar = remember { SnackbarHostState() }

    NotificationPermission()

    LaunchedEffect(vm.message) {
        vm.message?.let {
            snackbar.showSnackbar(it)
            vm.message = null
        }
    }

    Scaffold(
        topBar = { TopBar(vm, engine) },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (val e = engine) {
                is Engine.State.Loading -> item { InfoCard("Setting up yt-dlp… the first launch takes a few seconds.", busy = true) }
                is Engine.State.Failed -> item { InfoCard("yt-dlp could not be set up: ${e.message}", isError = true) }
                is Engine.State.Ready -> Unit
            }

            item { LinkCard(vm) }

            val media = vm.media
            when {
                vm.isFetching -> item { InfoCard("Reading link… large playlists can take a moment.", busy = true) }
                vm.fetchError != null -> item { InfoCard("Couldn't read that link.\n${vm.fetchError}", isError = true) }
                media != null -> {
                    item { MediaHeader(vm) }
                    items(media.entries, key = { it.id }) { entry ->
                        EntryRow(entry, showIndex = media.isPlaylist, onToggle = { vm.toggle(entry.id) })
                    }
                }
                else -> item {
                    InfoCard("Paste a YouTube video or playlist link, or use Share → YT Downloader in the YouTube app.")
                }
            }

            item { OptionsCard(vm) }

            item {
                val count = vm.selectedEntries.size
                Button(
                    onClick = vm::download,
                    enabled = count > 0 && engine is Engine.State.Ready,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        when {
                            vm.media == null -> "Download"
                            count == 1 -> "Download 1 ${if (vm.kind == MediaKind.AUDIO) "MP3" else "video"}"
                            else -> "Download $count ${if (vm.kind == MediaKind.AUDIO) "MP3s" else "videos"}"
                        }
                    )
                }
            }

            if (jobs.isNotEmpty()) {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Downloads", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        if (jobs.any { !it.state.isFinished }) {
                            TextButton(onClick = DownloadQueue::cancelAll) { Text("Cancel all") }
                        }
                        if (jobs.any { it.state.isFinished }) {
                            TextButton(onClick = DownloadQueue::clearFinished) { Text("Clear finished") }
                        }
                    }
                }
                items(jobs.asReversed(), key = { it.id }) { job ->
                    JobRow(job, onOpen = {
                        if (!openFile(context, job)) vm.message = "No app on this phone can open this file."
                    })
                }
            }
        }
    }
}

@Composable
private fun TopBar(vm: MainViewModel, engine: Engine.State) {
    var menuOpen by remember { mutableStateOf(false) }
    TopAppBar(
        title = { Text("YT Downloader") },
        actions = {
            if (vm.isUpdating) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
            }
            Box {
                IconButton(onClick = { menuOpen = true }) { Icon(Icons.Default.MoreVert, contentDescription = "More") }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Update yt-dlp") },
                        enabled = engine is Engine.State.Ready && !vm.isUpdating,
                        onClick = {
                            menuOpen = false
                            vm.updateYtDlp()
                        },
                    )
                    val version = (engine as? Engine.State.Ready)?.version
                    DropdownMenuItem(
                        text = { Text("yt-dlp version: ${version ?: "unknown"}") },
                        enabled = false,
                        onClick = {},
                    )
                }
            }
        },
    )
}

@Composable
private fun LinkCard(vm: MainViewModel) {
    val clipboard = LocalClipboardManager.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = vm.link,
            onValueChange = { vm.link = it },
            label = { Text("Video or playlist link") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { vm.fetch() }),
            trailingIcon = {
                if (vm.link.isNotEmpty()) {
                    IconButton(onClick = { vm.link = "" }) { Icon(Icons.Default.Close, contentDescription = "Clear") }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = {
                    val text = clipboard.getText()?.text?.trim().orEmpty()
                    if (text.isNotEmpty()) {
                        vm.link = text
                        vm.fetch(force = true)
                    }
                },
                modifier = Modifier.weight(1f),
            ) { Text("Paste & fetch") }
            Button(
                onClick = { vm.fetch() },
                enabled = !vm.isFetching && vm.link.isNotBlank(),
                modifier = Modifier.weight(1f),
            ) { Text("Fetch") }
        }
    }
}

@Composable
private fun MediaHeader(vm: MainViewModel) {
    val media = vm.media ?: return
    Column {
        Text(
            media.title,
            style = MaterialTheme.typography.titleMedium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (media.isPlaylist) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Playlist · ${media.entries.size} videos · ${vm.selectedEntries.size} selected",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { vm.setAllSelected(true) }) { Text("All") }
                TextButton(onClick = { vm.setAllSelected(false) }) { Text("None") }
            }
        }
        HorizontalDivider(Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun EntryRow(entry: VideoEntry, showIndex: Boolean, onToggle: () -> Unit) {
    val dim = if (entry.isAvailable) 1f else 0.4f
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = entry.isAvailable, onClick = onToggle),
    ) {
        Checkbox(checked = entry.isSelected, onCheckedChange = { onToggle() }, enabled = entry.isAvailable)
        if (showIndex && entry.playlistIndex != null) {
            Text(
                "${entry.playlistIndex}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = dim),
                modifier = Modifier.width(32.dp),
            )
        }
        Text(
            entry.title,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = dim),
            modifier = Modifier.weight(1f),
        )
        Text(
            formatDuration(entry.duration),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 8.dp),
        )
    }
}

@Composable
private fun OptionsCard(vm: MainViewModel) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Download as", style = MaterialTheme.typography.labelLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                MediaKind.entries.forEach { kind ->
                    FilterChip(selected = vm.kind == kind, onClick = { vm.kind = kind }, label = { Text(kind.title) })
                }
            }

            if (vm.kind == MediaKind.VIDEO) {
                ChoiceRow(
                    label = "Max quality",
                    current = vm.quality.title,
                    options = VideoQuality.entries.map { q -> q.title to { vm.quality = q } },
                )
                SwitchRow(
                    label = "Prefer H.264",
                    caption = "Plays on any phone or TV. Turn off for 1440p/4K, which YouTube mostly serves as VP9/AV1.",
                    checked = vm.preferH264,
                    onChange = { vm.preferH264 = it },
                )
            } else {
                ChoiceRow(
                    label = "MP3 bitrate",
                    current = "${vm.audioKbps} kbps",
                    options = audioBitrates.map { kbps -> "$kbps kbps" to { vm.updateAudioKbps(kbps) } },
                )
            }

            if (vm.media?.isPlaylist == true) {
                SwitchRow("Put playlist in its own folder", null, vm.playlistSubfolder) { vm.playlistSubfolder = it }
                SwitchRow("Number files by playlist order", null, vm.numberPlaylistFiles) { vm.numberPlaylistFiles = it }
            }

            Spacer(Modifier.height(4.dp))
            Text("Save to", style = MaterialTheme.typography.labelLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SaveLocation.entries.forEach { location ->
                    FilterChip(
                        selected = vm.saveLocation == location,
                        onClick = { vm.saveLocation = location },
                        label = { Text(location.title) },
                    )
                }
            }
            Text(
                vm.saveLocation.description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ChoiceRow(label: String, current: String, options: List<Pair<String, () -> Unit>>) {
    var open by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(label, modifier = Modifier.weight(1f))
        Box {
            TextButton(onClick = { open = true }) {
                Text(current)
                Icon(Icons.Default.ArrowDropDown, contentDescription = null)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                options.forEach { (title, select) ->
                    DropdownMenuItem(text = { Text(title) }, onClick = {
                        select()
                        open = false
                    })
                }
            }
        }
    }
}

@Composable
private fun SwitchRow(label: String, caption: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onChange(!checked) }
            .padding(vertical = 4.dp),
    ) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(label)
            if (caption != null) {
                Text(caption, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun JobRow(job: DownloadJob, onOpen: () -> Unit) {
    val state = job.state
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(start = 16.dp, top = 12.dp, bottom = 8.dp, end = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(job.entry.title, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val (status, isError) = when (state) {
                        JobState.Queued -> "Waiting" to false
                        JobState.Downloading -> job.detail to false
                        is JobState.Processing -> state.label to false
                        JobState.Done -> "Saved to ${job.detail}" to false
                        is JobState.Failed -> state.message to true
                        JobState.Cancelled -> "Cancelled" to false
                    }
                    Text(
                        status,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                when {
                    !state.isFinished -> IconButton(onClick = { DownloadQueue.cancel(job.id) }) {
                        Icon(Icons.Default.Close, contentDescription = "Cancel")
                    }
                    else -> {
                        if (state == JobState.Done && job.savedUri != null) {
                            TextButton(onClick = onOpen) { Text("Open") }
                        }
                        if (state is JobState.Failed || state == JobState.Cancelled) {
                            IconButton(onClick = { DownloadQueue.retry(job.id) }) {
                                Icon(Icons.Default.Refresh, contentDescription = "Retry")
                            }
                        }
                        IconButton(onClick = { DownloadQueue.remove(job.id) }) {
                            Icon(Icons.Default.Delete, contentDescription = "Remove from list")
                        }
                    }
                }
            }
            when (state) {
                JobState.Downloading -> LinearProgressIndicator(
                    progress = { job.progress },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp, end = 12.dp),
                )
                is JobState.Processing -> LinearProgressIndicator(
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp, end = 12.dp),
                )
                else -> Unit
            }
        }
    }
}

@Composable
private fun InfoCard(text: String, busy: Boolean = false, isError: Boolean = false) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = if (isError) MaterialTheme.colorScheme.errorContainer
            else MaterialTheme.colorScheme.surfaceContainer,
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            if (busy) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(12.dp))
            }
            Text(
                text,
                color = if (isError) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

/** Asks once for permission to show download progress in the notification shade (Android 13+). */
@Composable
private fun NotificationPermission() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    LaunchedEffect(Unit) {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}

private fun openFile(context: Context, job: DownloadJob): Boolean {
    val uri = job.savedUri ?: return false
    val intent = Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, job.savedMime ?: "*/*")
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    return try {
        context.startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        false
    }
}
