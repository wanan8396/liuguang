package cn.liuguang.engine

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

internal class PlayerResolver(private val proxy: LocalProxy,private val sniffer: WebSniffer) {
    companion object {
        fun parserFromJson(json: String): JSONObject = when (val value = JSONTokener(json).nextValue()) {
            is JSONObject -> value
            is JSONArray -> if (value.length()==0) JSONObject() else requireNotNull(value.optJSONObject(0)) { "First parser must be an object" }
            else -> throw IllegalArgumentException("Parser must be an object or array")
        }
        /** TVBox quality lists alternate display names and media URLs. */
        fun playbackUrl(value: Any?): String = when (value) {
            is String -> value
            is JSONArray -> {
                require(value.length() > 0 && value.length() % 2 == 0) { "Invalid playback quality list" }
                val choices = (0 until value.length() step 2).map { index ->
                    require(value.opt(index) is String && value.opt(index + 1) is String) { "Invalid playback quality entry" }
                    val url = value.getString(index + 1)
                    require(url.startsWith("http://") || url.startsWith("https://")) { "Invalid playback quality URL" }
                    url
                }
                choices.first()
            }
            else -> error("Player response has no URL")
        }
    }
    private fun headers(obj: JSONObject): Map<String,String> {
        val h=when(val raw=obj.opt("header") ?: obj.opt("headers")) { is JSONObject -> raw; is String -> runCatching { JSONObject(raw) }.getOrDefault(JSONObject()); else -> JSONObject() }
        return h.keys().asSequence().associateWith { h.optString(it) }
    }
    private fun mediaResponse(s: EngineSession,url: String,h: Map<String,String>): Boolean {
        if(EngineRules.media(url)) return true
        return runCatching {
            val request=HostHttp.request(url,h).header("Range","bytes=0-511").build()
            HostHttp.execute(s.id,request).use { response ->
                if(!response.isSuccessful) return@use false
                val type=response.header("Content-Type").orEmpty().substringBefore(';').lowercase()
                if(type.startsWith("video/") || type.startsWith("audio/") || type in setOf("application/vnd.apple.mpegurl","application/x-mpegurl","application/dash+xml","application/mp4")) return@use true
                val bytes=response.body?.byteStream()?.let { BoundedIo.read(it,512) } ?: return@use false
                val text=bytes.toString(Charsets.UTF_8).trimStart()
                text.startsWith("#EXTM3U") || text.startsWith("<MPD") || text.contains("<MPD ") || (bytes.size>=12 && bytes.copyOfRange(4,8).toString(Charsets.US_ASCII)=="ftyp") || (bytes.size>=188 && bytes[0]==0x47.toByte())
            }
        }.getOrDefault(false)
    }
    fun resolve(s: EngineSession,result: JSONObject,parser: JSONObject): String {
        val original=JSONObject(result.toString())
        var url=playbackUrl(result.opt("url")).ifBlank { error("Player response has no URL") }
        var h=headers(result)
        val parse=result.optInt("parse",0)!=0 || result.optInt("jx",0)!=0
        val prefix=result.optString("playUrl")
        val parserUrl=parser.optString("url",prefix)
        val parserType=parser.optInt("type",0)
        EngineRules.legacyHlsTarget(url)?.let { url=it }
        if(EngineRules.loopback(url)) {
            require(EngineRules.localRoute(url)) { "Local URL is outside documented plugin routes" }
            url=proxy.rewrite(s,url)
        }
        if(parse && parserType in listOf(2,3)) {
            val parsed=s.parser(parser,result.optString("flag"),url)
            original.keys().asSequence().toList().forEach { if(!parsed.has(it) && it !in listOf("parse","jx","playUrl")) parsed.put(it,original.opt(it)) }
            parsed.put("parse",parsed.optInt("parse",0)).put("jx",0).put("playUrl","")
            require(parsed.optString("url").isNotBlank()) { "JAR parser returned no URL" }
            return resolve(s,parsed,JSONObject())
        }
        if(parse && parserType==1 && parserUrl.isNotBlank()) {
            val target=parserUrl+url
            val parsed=HostHttp.execute(s.id,HostHttp.request(target,h).build()).use { response -> check(response.isSuccessful) { "Parser HTTP ${response.code}" }; val data=response.body?.byteStream()?.let { BoundedIo.read(it,2*1024*1024+1) } ?: error("Empty parser body"); require(data.size<=2*1024*1024); JSONObject(data.toString(Charsets.UTF_8)) }
            val payload=parsed.optJSONObject("data")?.takeIf { it.has("url") } ?: parsed
            val merged=HashMap(h); merged.putAll(headers(payload)); h=merged
            url=playbackUrl(payload.opt("url")).ifBlank { error("JSON parser returned no playable URL") }
            payload.keys().forEach { name -> if(name !in listOf("header","headers")) original.put(name,payload.opt(name)) }
            original.put("parse",payload.optInt("parse",0))
        } else if(parse && parserUrl.isNotBlank()) url=parserUrl+url
        val mustSniff=(parse && parserType==0 && parserUrl.isNotBlank())
        if(mustSniff || (!EngineRules.loopback(url) && !mediaResponse(s,url,h))) {
            val hit=sniffer.sniff(s,url,h); url=hit.url; h=hit.headers
        }
        require(url.startsWith("http://") || url.startsWith("https://")) { "Unsupported resolved media protocol" }
        if(EngineRules.loopback(url)) require(EngineRules.localRoute(url) || java.net.URI(url).port==proxy.listeningPort) { "Unknown local media endpoint" }
        // Do not buffer media or serialize bytes over Pigeon. Preserve all headers in DTO and stream target.
        val playback=if(EngineRules.loopback(url)) url else proxy.stream(s,url,h)
        return original.put("url",playback).put("originalUrl",url).put("header",JSONObject(h)).put("headers",JSONObject(h)).put("parse",0).put("jx",0).put("playUrl","").toString()
    }
}
