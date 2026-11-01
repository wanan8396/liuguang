package cn.liuguang.engine

import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.URI
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal class LocalProxy(private val lifecycle: EngineLifecycle<EngineSession>) : NanoHTTPD("127.0.0.1",0), AutoCloseable {
    private val sessions = lifecycle.sessions
    private val token=UUID.randomUUID().toString()
    data class StreamTarget(val session: String,val url: String,val headers: Map<String,String>)
    private val streams=ConcurrentHashMap<String,StreamTarget>()
    private val legacyFailures=ConcurrentHashMap<Int,String>()
    private var closed=false
    fun enableLegacy(id: String, ports: Set<Int>, required: Boolean) = synchronized(lifecycle.lock) {
        check(!closed) { "Proxy closed" }
        lifecycle.acquirePorts(id, ports, required, { port ->
            val listener=object: NanoHTTPD("127.0.0.1",port) { override fun serve(request: IHTTPSession): Response = this@LocalProxy.serve(request) }
            object: EngineLifecycle.Listener {
                override fun start() { listener.start(SOCKET_READ_TIMEOUT,false); legacyFailures.remove(port) }
                override fun stop() { listener.stop() }
            }
        }, { port, error ->
            legacyFailures[port]="${error.javaClass.simpleName}: ${error.message.orEmpty()}"
            android.util.Log.w("SourceEngine", "${if(required) "Required" else "Optional"} legacy port $port unavailable", error)
        })
    }
    fun legacyDiagnostics(): JSONObject = JSONObject(legacyFailures.mapKeys { it.key.toString() })
    init { start(SOCKET_READ_TIMEOUT,false); com.github.catvod.Proxy.setUrl("http://127.0.0.1:$listeningPort/proxy") }
    val base get()="http://127.0.0.1:$listeningPort"
    fun pluginUrl(s: EngineSession) = "$base/proxy?sid=${s.id}&token=$token"
    fun stream(s: EngineSession,url: String,headers: Map<String,String>): String {
        val key=UUID.randomUUID().toString(); streams[key]=StreamTarget(s.id,url,headers)
        return "$base/stream/$key?token=$token"
    }
    fun remove(id: String) { streams.entries.removeAll { it.value.session==id } }
    fun rewrite(s: EngineSession,url: String): String {
        if(!EngineRules.localRoute(url)) return url
        val uri=android.net.Uri.parse(url)
        require(uri.port in EngineRules.legacyPorts || uri.port==listeningPort) { "Unknown localhost engine port" }
        return android.net.Uri.parse(pluginUrl(s)).buildUpon().apply { uri.queryParameterNames.filter { it !in setOf("sid","token") }.forEach { name -> appendQueryParameter(name,uri.getQueryParameter(name)) } }.build().toString()
    }
    fun localText(s: EngineSession,url: String): String {
        require(EngineRules.localRoute(url)) { "Only documented localhost plugin routes may be fetched" }
        val routed=rewrite(s,url)
        val uri=android.net.Uri.parse(routed)
        val params=uri.queryParameterNames.associateWith { uri.getQueryParameter(it).orEmpty() }
        return body(s.proxy(params)).use { input -> val bytes=BoundedIo.read(input,4*1024*1024+1); require(bytes.size<=4*1024*1024) { "Local text exceeds 4 MiB; media must be streamed" }; bytes.toString(Charsets.UTF_8) }
    }
    private fun body(result: Array<*>): InputStream = when(val value=result.getOrNull(2)) { is InputStream -> value; is ByteArray -> ByteArrayInputStream(value); null -> ByteArrayInputStream(byteArrayOf()); else -> ByteArrayInputStream(value.toString().toByteArray()) }
    override fun serve(request: IHTTPSession): Response = try {
        require(request.headers["origin"].isNullOrBlank()) { "Cross-origin engine requests are forbidden" }
        require(request.method==Method.GET || request.method==Method.HEAD) { "Only GET/HEAD engine routes are supported" }
        val p=request.parameters.mapValues { it.value.firstOrNull().orEmpty() }
        when {
            request.uri.startsWith("/stream/") -> {
                require(p["token"]==token) { "Invalid proxy token" }
                val target=streams[request.uri.substringAfterLast('/')] ?: error("Stream expired")
                val s=sessions[target.session] ?: error("Session closed")
                val builder=HostHttp.request(target.url,target.headers)
                request.headers["range"]?.let { builder.header("Range",it) }
                if(request.method==Method.HEAD) builder.head()
                val upstream=HostHttp.execute(s.id,builder.build())
                val responseBody=upstream.body
                val mime=upstream.header("Content-Type").orEmpty().lowercase()
                val prefix=responseBody?.source()?.peek()?.readByteArray(minOf(responseBody.contentLength().takeIf { it>=0 } ?: 8,8))?.toString(Charsets.UTF_8).orEmpty()
                if(request.method!=Method.HEAD && upstream.isSuccessful && (mime.contains("mpegurl") || target.url.substringBefore('?').endsWith(".m3u8") || prefix.startsWith("#EXTM3U"))) {
                    val manifest=responseBody?.byteStream()?.let { BoundedIo.read(it,4*1024*1024+1) } ?: byteArrayOf()
                    upstream.close(); require(manifest.size<=4*1024*1024) { "HLS manifest exceeds 4MiB" }
                    val rewritten=manifest.toString(Charsets.UTF_8).lineSequence().joinToString("\n") { line ->
                        if(line.isBlank()) line
                        else if(line.startsWith("#")) Regex("URI=\"([^\"]+)\"").replace(line) { match -> "URI=\""+stream(s,EngineRules.resolve(target.url,match.groupValues[1]),target.headers)+"\"" }
                        else stream(s,EngineRules.resolve(target.url,line.trim()),target.headers)
                    }
                    return newFixedLengthResponse(Response.Status.OK,"application/vnd.apple.mpegurl",rewritten)
                }
                val input=object: java.io.FilterInputStream(responseBody?.byteStream() ?: ByteArrayInputStream(byteArrayOf())) { override fun close() { try { super.close() } finally { upstream.close() } } }
                val status=Response.Status.lookup(upstream.code) ?: Response.Status.OK
                val response=if(responseBody!=null && responseBody.contentLength()>=0) newFixedLengthResponse(status,upstream.header("Content-Type","application/octet-stream"),input,if(request.method==Method.HEAD) 0 else responseBody.contentLength()) else newChunkedResponse(status,upstream.header("Content-Type","application/octet-stream"),input)
                listOf("Content-Range","Accept-Ranges","Cache-Control","ETag","Last-Modified").forEach { name -> upstream.header(name)?.let { response.addHeader(name,it) } }
                response
            }
            request.uri=="/file" || request.uri.startsWith("/file/") -> {
                // Legacy csp hard-codes /file/name. It remains a trusted-plugin boundary,
                // NOT a UID sandbox: never accept paths or silently select an ambiguous name.
                val name=p["name"] ?: request.uri.removePrefix("/file/")
                require(name.matches(Regex("[A-Za-z0-9_.-]{1,80}")) && name !in listOf(".","..")) { "Credential name, not a path, is required" }
                val candidates=p["sid"]?.let { listOfNotNull(sessions[it]) } ?: sessions.values.filter { !it.closed && it.credentials.has(name) }
                require(candidates.isNotEmpty()) { "Credential not supplied by an active trusted session" }
                val values=candidates.map { it.credentials.optString(name) }.distinct()
                require(values.size==1) { "Ambiguous credential name; use an explicit session id" }
                newFixedLengthResponse(Response.Status.OK,"text/plain; charset=utf-8",values.single()).apply { addHeader("Cache-Control","no-store") }
            }
            request.uri in listOf("/proxy","/proxy/","/") -> {
                val s=p["sid"]?.let { sessions[it] } ?: p["siteKey"]?.let { k -> sessions.values.singleOrNull { it.key==k } } ?: sessions.values.singleOrNull()
                requireNotNull(s) { "Missing or ambiguous plugin session" }
                val result=s.proxy(p)
                val response=newChunkedResponse(Response.Status.lookup((result[0] as Number).toInt()) ?: Response.Status.OK,result[1].toString(),body(result))
                when(val h=result.getOrNull(3)) { is Map<*,*> -> h.forEach { (k,v) -> if(k!=null && v!=null) response.addHeader(k.toString(),v.toString()) }; is String -> runCatching { JSONObject(h) }.getOrNull()?.let { obj -> obj.keys().forEach { response.addHeader(it,obj.get(it).toString()) } } }
                response
            }
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND,"text/plain","Unknown engine route")
        }
    } catch(e: Throwable) { newFixedLengthResponse(Response.Status.BAD_REQUEST,"text/plain",e.message ?: "Proxy error") }
    override fun close() = synchronized(lifecycle.lock) {
        if (!closed) {
            closed=true
            lifecycle.stopPorts()
            stop()
            streams.clear()
        }
        Unit
    }
}
