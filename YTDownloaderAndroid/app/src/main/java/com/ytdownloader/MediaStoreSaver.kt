package com.ytdownloader

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import java.io.File
import java.io.IOException

/** Copies a finished file into the phone's shared Movies, Music or Download folder. No storage permission needed. */
object MediaStoreSaver {
    const val FOLDER = "YT Downloader"

    data class Saved(val uri: Uri, val mime: String, val displayPath: String)

    fun save(context: Context, file: File, options: DownloadOptions): Saved {
        val resolver = context.contentResolver
        val ext = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: if (ext == "mp3") "audio/mpeg" else "video/mp4"
        val isAudio = mime.startsWith("audio/")
        val volume = MediaStore.VOLUME_EXTERNAL_PRIMARY

        val (collection, baseDir) = when (options.saveLocation) {
            SaveLocation.MEDIA ->
                if (isAudio) MediaStore.Audio.Media.getContentUri(volume) to Environment.DIRECTORY_MUSIC
                else MediaStore.Video.Media.getContentUri(volume) to Environment.DIRECTORY_MOVIES
            SaveLocation.DOWNLOADS -> MediaStore.Downloads.getContentUri(volume) to Environment.DIRECTORY_DOWNLOADS
        }
        val relativePath = buildString {
            append(baseDir).append('/').append(FOLDER)
            options.subfolder?.let { append('/').append(it) }
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IOException("Android refused to create the file in $relativePath")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { it.copyTo(out, bufferSize = 1 shl 16) }
            } ?: throw IOException("Could not open $relativePath for writing")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return Saved(uri, mime, "$relativePath/${file.name}")
    }
}
