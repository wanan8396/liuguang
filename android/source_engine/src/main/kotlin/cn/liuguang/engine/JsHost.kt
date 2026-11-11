package cn.liuguang.engine

import android.os.Build
import android.util.Base64
import android.util.Log
import com.fongmi.quickjs.QuickJS
import org.json.JSONArray
import org.json.JSONObject
import okhttp3.FormBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import java.io.ByteArrayInputStream
import java.util.concurrent.TimeUnit

/** Uses the Java wrapper and native runtime from the SAME FongMi commit. */
class JsHost(private val session: EngineSession,private val api: String): AutoCloseable {
    private val q: QuickJS
    private val local=session.context.getSharedPreferences("drpy-"+EngineRules.digest((session.base+session.key).toByteArray()),0)
    init {
        require(Build.SUPPORTED_ABIS.any { it in listOf("arm64-v8a","armeabi-v7a") }) { "Bundled QuickJS runtime supports ARM64/ARMv7; current device ${Build.SUPPORTED_ABIS.joinToString()}" }
        q=QuickJS({ System.loadLibrary("quickjs-wrapper") })
        q.setLimits(64L*1024*1024,2L*1024*1024).get()
        bind("__req") { args -> req(args[0].toString(),JSONObject(args.getOrNull(1)?.toString() ?: "{}")) }
        bind("__pdfh") { a -> HtmlAdapter.value(a[0].toString(),a[1].toString(),a.getOrNull(2)?.toString().orEmpty()) }
        bind("__pdfa") { a -> JSONArray(HtmlAdapter.array(a[0].toString(),a[1].toString())).toString() }
        bind("__local") { a -> val k=a[1].toString()+"/"+a[2].toString(); when(a[0].toString()) { "get" -> local.getString(k,a.getOrNull(3)?.toString().orEmpty()); "set" -> { local.edit().putString(k,a[3].toString()).apply(); true }; "delete" -> { local.edit().remove(k).apply(); true }; else -> error("Unknown local storage operation") } }
        bind("__proxy") { _ -> com.github.catvod.Proxy.getUrl(true)+"?sid="+session.id+"&do=js" }
        bind("__log") { _ -> null }
        bind("__joinUrl") { a -> EngineRules.resolve(a[0].toString(),a[1].toString()) }
        com.fongmi.quickjs.Encoding.install(q).get()
        q.setModuleLoader(object: QuickJS.ModuleLoader {
            override fun normalize(base: String?,name: String): String = if(name.startsWith("assets://") || name.startsWith("http")) name else EngineRules.resolve(base?.takeIf { it.isNotBlank() } ?: api,name)
            override fun load(name: String): String = if (name == api && session.site.optString("_jsSource").isNotBlank()) session.site.getString("_jsSource") else session.resource(name).toString(Charsets.UTF_8)
        }).get()
        q.evaluate(session.context.assets.open("engine/host.js").bufferedReader().use { it.readText() },"assets://engine/host.js").get()
        q.evaluateModule("import 'assets://js/lib/crypto-js.js';", "assets://engine/crypto-init.js").get()
    }
    private fun bind(name: String, fn: (Array<out Any?>)->Any?) { q.bind(name,QuickJS.Function { a -> fn(a) }).get() }
    private fun req(url: String,options: JSONObject): String {
        val headers=options.optJSONObject("headers")?.let { o -> o.keys().asSequence().associateWith { o.optString(it) } } ?: emptyMap()
        val builder=HostHttp.request(url,headers)
        val method=options.optString("method","GET").uppercase()
        if(method !in listOf("GET","HEAD")) {
            val data=options.opt("data") ?: options.opt("body") ?: ""
            val body=if(data is JSONObject && options.optString("postType")=="form") FormBody.Builder().apply { data.keys().forEach { add(it,data.optString(it)) } }.build() else data.toString().toRequestBody((headers.entries.firstOrNull { it.key.equals("Content-Type",true) }?.value ?: "application/x-www-form-urlencoded").toMediaTypeOrNull())
            builder.method(method,body)
        } else if(method=="HEAD") builder.head()
        HostHttp.execute(session.id,builder.build()).use { r ->
            val body=r.body; val bytes=body?.byteStream()?.use { input -> BoundedIo.read(input,8*1024*1024+1) } ?: byteArrayOf()
            require(bytes.size<=8*1024*1024) { "JS req body exceeds 8MiB; use local proxy for video" }
            val buffer=options.optInt("buffer",0)
            val content: Any=when(buffer) { 1 -> JSONArray(bytes.map { it.toInt() and 255 }); 2 -> Base64.encodeToString(bytes,Base64.NO_WRAP); else -> bytes.toString(runCatching { java.nio.charset.Charset.forName(options.optString("charset",body?.contentType()?.charset()?.name() ?: "UTF-8")) }.getOrDefault(Charsets.UTF_8)) }
            return JSONObject().put("code",r.code).put("content",content).put("headers",JSONObject(r.headers.toMultimap())).put("url",r.request.url.toString()).toString()
        }
    }
    fun init(ext: String) {
        val source=session.site.optString("_jsSource").takeIf { it.isNotBlank() }
            ?: session.resource(api).toString(Charsets.UTF_8)
        if(source.trimStart().startsWith("//bb")) error("Precompiled JS bytecode is runtime-version-specific; provide source JS")
        // Traditional drpy rules use global `rule`; ES modules export __jsEvalReturn/default.
        if(source.contains("export ") || source.contains("export{")) {
            q.evaluateModule(source.replace("var __JS_SPIDER__", "globalThis.__JS_SPIDER__"),api).get()
            q.evaluateModule("import * as m from ${JSONObject.quote(api)}; globalThis.__spider=globalThis.__JS_SPIDER__||(m.__jsEvalReturn?m.__jsEvalReturn():(typeof m.default==='function'?m.default():m.default));",api+"#entry").get()
        } else {
            q.evaluate(source,api).get()
            q.evaluateModule("import drpy from 'assets://drpy/libs/drpy2.js'; globalThis.__spider=typeof __JS_SPIDER__!=='undefined'?__JS_SPIDER__:drpy; globalThis.__ruleMode=typeof rule!=='undefined';",api+"#rule").get()
        }
        q.evaluate("if(!globalThis.__spider) throw Error('No drpy rule or spider module export');").get()
        val argument=runCatching { JSONObject(ext); ext }.getOrElse { JSONObject.quote(ext) }
        q.evaluateTimed(30000,"typeof __spider.init==='function'?__spider.init(globalThis.__ruleMode?rule:$argument):null",api+"#init").get(35,TimeUnit.SECONDS)
    }
    fun call(method: String,vararg args: Any): String {
        val name=when(method) { "home" -> "home"; "category" -> "category"; "search" -> "search"; "detail" -> "detail"; "play" -> "play"; else -> method }
        val adapted: List<Any> = when(method) {
            "category" -> listOf(args[0],args[1],true,JSONObject(args[2] as Map<*,*>))
            "search" -> listOf(args[0],false,args[1])
            "play" -> listOf(args[0],args[1],JSONArray())
            else -> args.toList()
        }
        val json=JSONArray(adapted).toString()
        val aliases=JSONObject(mapOf("home" to "homeContent","category" to "categoryContent","search" to "searchContent","detail" to "detailContent","play" to "playerContent")).optString(name,name)
        val code="(async()=>{const s=__spider;const fn=s[${JSONObject.quote(name)}]||s[${JSONObject.quote(aliases)}]; if(!fn) throw Error('Missing spider method: $name'); let a=$json; if('$method'==='detail'&&!s.detail)a=[a]; const v=await fn.apply(s,a); return typeof v==='string'?v:JSON.stringify(v);})()"
        val result=q.evaluateTimed(30000,code,api+"#"+method).get(35,TimeUnit.SECONDS).toString()
        val jsonResult=JSONObject(result)
        if(method=="home" && (jsonResult.optJSONArray("list")?.length() ?: 0) == 0) {
            return HomeResponse.merge(result) {
                q.evaluateTimed(30000,"(async()=>{const fn=__spider.homeVod||__spider.homeVideoContent;if(!fn)return null;const v=await fn.call(__spider);return typeof v==='string'?v:JSON.stringify(v);})()",api+"#homeVod").get(35,TimeUnit.SECONDS)?.toString().orEmpty()
            }
        }
        return jsonResult.toString()
    }
    fun proxy(params: Map<String,String>): Array<*> {
        val code="(()=>{if(!__spider.proxy)throw Error('JS has no proxy');let v=__spider.proxy(${JSONObject(params)});return typeof v==='string'?v:JSON.stringify(v);})()"
        val a=JSONArray(q.evaluateTimed(30000,code,api+"#proxy").get().toString())
        val bytes=when(val v=a.opt(2)) { is JSONArray -> ByteArray(v.length()) { v.optInt(it).toByte() }; else -> if(a.optInt(4)==1) Base64.decode(v.toString().substringAfter("base64,"),Base64.DEFAULT) else v.toString().toByteArray() }
        return arrayOf(a.getInt(0),a.getString(1),ByteArrayInputStream(bytes),a.optJSONObject(3)?.let { obj -> obj.keys().asSequence().associateWith { obj.getString(it) } } ?: emptyMap<String,String>())
    }
    fun cancel() { q.cancelPending() }
    override fun close() { q.cancelPending(); q.close() }
}
