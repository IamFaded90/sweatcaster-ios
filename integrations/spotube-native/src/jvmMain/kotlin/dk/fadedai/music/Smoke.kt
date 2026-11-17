package dk.fadedai.music

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

fun main() = runBlocking {
    val client = FadedMusicClient()
    val tracks = Json.parseToJsonElement(client.searchJson("Kevin MacLeod Carefree"))
        .jsonObject.getValue("tracks").jsonArray
    println("NewPipe music search: ${tracks.size} tracks")
    check(tracks.isNotEmpty())
    val id = tracks.first().jsonObject.getValue("id").jsonPrimitive.content
    val url = Json.parseToJsonElement(client.streamJson(id)).jsonObject.getValue("url").jsonPrimitive.content
    val request = HttpRequest.newBuilder(URI(url)).timeout(Duration.ofSeconds(30)).GET().build()
    val response = HttpClient.newHttpClient().send(request, HttpResponse.BodyHandlers.ofInputStream())
    response.body().use {
        val sample = it.readNBytes(4096)
        val type = response.headers().firstValue("Content-Type").orElse("")
        println("NewPipe actual audio: HTTP ${response.statusCode()}, $type, ${sample.size} bytes")
        check(response.statusCode() == 200 && sample.isNotEmpty() && (type.startsWith("audio/") || type.startsWith("video/")))
    }
}
