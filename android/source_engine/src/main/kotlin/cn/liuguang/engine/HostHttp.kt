package cn.liuguang.engine

import okhttp3.*
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

object HostHttp {
    val client: OkHttpClient = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS).followRedirects(true).build()
    private val calls = ConcurrentHashMap<String, MutableSet<Call>>()
    fun cancel(tag: String) { calls.remove(tag)?.forEach { it.cancel() } }
    fun execute(tag: String, request: Request): Response {
        val call = client.newCall(request)
        val set = calls.computeIfAbsent(tag) { ConcurrentHashMap.newKeySet() }
        set.add(call)
        try { return call.execute() } finally { set.remove(call) }
    }
    fun request(url: String, headers: Map<String,String> = emptyMap()): Request.Builder {
        require(URI(url).scheme in listOf("http", "https")) { "Only HTTP(S) is supported: $url" }
        return Request.Builder().url(url).header("User-Agent", "okhttp/4.9.1").apply { headers.forEach { (k,v) -> header(k,v) } }
    }
    fun bytes(tag: String, url: String, max: Long = 32L*1024*1024): ByteArray = execute(tag,request(url).build()).use { r ->
        check(r.isSuccessful) { "HTTP ${r.code}: $url" }
        val body = r.body ?: error("HTTP body is missing")
        require(body.contentLength() <= max) { "Response exceeds $max bytes" }
        body.byteStream().use { input ->
            val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(16384)
            while (true) { if (Thread.currentThread().isInterrupted) throw InterruptedException(); val n = input.read(buf); if(n<0) break; require(out.size()+n<=max) { "Response exceeds $max bytes" }; out.write(buf,0,n) }; out.toByteArray()
        }
    }
}
