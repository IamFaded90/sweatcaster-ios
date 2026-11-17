// Search and stream mapping adapted from Spotube NewPipeService.ios.kt.
// Copyright (C) 2026 Kingkor Roy Tirtho and Spotube Contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
package dk.fadedai.music

import com.yushosei.newpipe.extractor.NewPipe
import com.yushosei.newpipe.extractor.ServiceList.YouTube
import com.yushosei.newpipe.extractor.stream.StreamInfoItem
import com.yushosei.newpipe.extractor.youtube.linkHandler.YoutubeSearchQueryHandlerFactory
import com.yushosei.newpipe.util.DefaultDownloaderImpl
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/** Only strings cross the Swift boundary. Music data never reaches a model or PC. */
@OptIn(ExperimentalObjCName::class)
@ObjCName(name = "FadedMusicClient", exact = true)
class FadedMusicClient {
    private companion object {
        val initialization = Mutex()
        var initialized = false
        suspend fun initialize() = initialization.withLock {
            if (!initialized) {
                NewPipe.init(DefaultDownloaderImpl.initDefault())
                initialized = true
            }
        }
    }

    @Throws(Exception::class)
    suspend fun searchJson(query: String): String = withContext(Dispatchers.IO) {
        require(query.trim().length in 1..160) { "Skriv sang eller kunstner." }
        initialize()
        val extractor = YouTube.getSearchExtractor(query.trim(),
            mutableListOf(YoutubeSearchQueryHandlerFactory.MUSIC_SONGS), "")
        extractor.fetchPage()
        val tracks = extractor.initialPage.items.filterIsInstance<StreamInfoItem>().take(20).mapNotNull { item ->
            val id = Regex("[?&]v=([A-Za-z0-9_-]{11})").find(item.url)?.groupValues?.get(1)
                ?: return@mapNotNull null
            buildJsonObject {
                put("id", id)
                put("title", item.name.take(240))
                put("artist", (item.uploaderName ?: "YouTube").take(160))
                if (item.duration > 0) put("duration", item.duration)
            }
        }
        buildJsonObject { put("tracks", JsonArray(tracks)) }.toString()
    }

    @Throws(Exception::class)
    suspend fun streamJson(id: String): String = withContext(Dispatchers.IO) {
        require(Regex("[A-Za-z0-9_-]{11}").matches(id)) { "Ugyldigt musiknummer." }
        initialize()
        val extractor = YouTube.getStreamExtractor("https://www.youtube.com/watch?v=$id")
        extractor.fetchPage()
        val audio = extractor.audioStreams().filter { it.isUrl() && it.format != null }
        val compatible = audio.filter { it.format?.suffix in listOf("m4a", "mp4", "aac") }
            .maxByOrNull { it.bitrate } ?: throw Exception("Ingen iPhone-kompatibel lyd fundet.")
        require(compatible.content.startsWith("https://")) { "Ugyldig lydkilde." }
        buildJsonObject { put("url", compatible.content); put("expiresIn", 1800) }.toString()
    }
}
