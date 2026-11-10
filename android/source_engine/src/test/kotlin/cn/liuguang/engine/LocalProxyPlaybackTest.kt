package cn.liuguang.engine

import android.content.ContextWrapper
import fi.iki.elonen.NanoHTTPD
import java.io.File
import java.net.URI
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LocalProxyPlaybackTest {
    private class TestContext(private val directory: File) : ContextWrapper(null) {
        override fun getCodeCacheDir(): File = directory
    }

    @Test fun redirectedHlsUsesFinalBaseForSegmentsAndKeyUris() {
        val directory = Files.createTempDirectory("proxy-playback-").toFile()
        val requests = CopyOnWriteArrayList<Pair<String, String?>>()
        val key = ByteArray(16) { it.toByte() }
        val segment = ByteArray(188) { 0x47.toByte() }
        val manifest = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"../keys/test.key\"\n#EXTINF:5,\nparts/one.ts\n"
        val origin = object : NanoHTTPD("127.0.0.1", 0) {
            override fun serve(request: IHTTPSession): Response {
                val path = request.uri
                requests.add(path to request.headers["origin"])
                if (path == "/old/master") {
                    return newFixedLengthResponse(Response.Status.REDIRECT, "text/plain", "").apply {
                        addHeader("Location", "/cdn/dir/master.m3u8")
                    }
                }
                val bytes = when (path) {
                    "/cdn/dir/master.m3u8" -> manifest.toByteArray()
                    "/cdn/keys/test.key" -> key
                    "/cdn/dir/parts/one.ts" -> segment
                    else -> "not found".toByteArray()
                }
                val status = if (path in setOf("/cdn/dir/master.m3u8", "/cdn/keys/test.key", "/cdn/dir/parts/one.ts")) Response.Status.OK else Response.Status.NOT_FOUND
                val mime = if (path.endsWith(".m3u8")) "application/vnd.apple.mpegurl" else "application/octet-stream"
                return newFixedLengthResponse(status, mime, bytes.inputStream(), bytes.size.toLong())
            }
        }
        origin.start()
        val session = EngineSession(TestContext(directory), JSONObject(), JSONObject())
        val lifecycle = EngineLifecycle<EngineSession>()
        lifecycle.begin(session.id, session)
        lifecycle.publish(session.id)
        val proxy = LocalProxy(lifecycle)
        try {
            val url = proxy.stream(session, "http://127.0.0.1:${origin.listeningPort}/old/master", mapOf("Origin" to "https://site.invalid"))
            val rewritten = URI(url).toURL().openStream().use { it.readBytes().toString(Charsets.UTF_8) }
            val keyUrl = Regex("URI=\"([^\"]+)\"").find(rewritten)!!.groupValues[1]
            val segmentUrl = rewritten.lineSequence().first { it.startsWith("http://") }
            assertArrayEquals(key, URI(keyUrl).toURL().openStream().use { it.readBytes() })
            assertArrayEquals(segment, URI(segmentUrl).toURL().openStream().use { it.readBytes() })
            assertEquals(listOf("/old/master", "/cdn/dir/master.m3u8", "/cdn/keys/test.key", "/cdn/dir/parts/one.ts"), requests.map { it.first })
            assertTrue(requests.all { it.second == "https://site.invalid" })
        } finally {
            proxy.close()
            session.close()
            origin.stop()
            directory.deleteRecursively()
        }
    }

    @Test fun crossOriginMediaProxyRequestsRemainRejected() {
        val proxy = LocalProxy(EngineLifecycle())
        try {
            val request = HostHttp.request("${proxy.base}/stream/unknown?token=unknown", mapOf("Origin" to "https://site.invalid")).build()
            HostHttp.client.newCall(request).execute().use { response ->
                assertEquals(400, response.code)
                assertEquals("Cross-origin engine requests are forbidden", response.body.string())
            }
        } finally {
            proxy.close()
        }
    }
}
