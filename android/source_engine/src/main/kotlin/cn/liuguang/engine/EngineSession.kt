package cn.liuguang.engine

import android.content.Context
import android.os.Build
import com.github.catvod.crawler.Spider
import dalvik.system.DexClassLoader
import org.json.JSONObject
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Modifier
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipFile

open class EngineSession(val context: Context, val config: JSONObject, val site: JSONObject) : AutoCloseable {
    val id: String = UUID.randomUUID().toString()
    val key: String = site.optString("key", id)
    val generation = AtomicLong()
    @Volatile var closed = false
    val lock = Any()
    val raw: JSONObject = config.optJSONObject("raw") ?: JSONObject()
    val credentials: JSONObject = config.optJSONObject("_privateCredentials") ?: JSONObject()
    var spider: Spider? = null
    var loader: DexClassLoader? = null
    val base: String = config.optString("url", "https://local.invalid/")
    var js: JsHost? = null
    private val folder = File(context.codeCacheDir, "source_engine").apply { mkdirs() }
    fun initialize() {
        preparePluginDirs()
        val api = site.optString("api")
        val type = site.optInt("type", 0)
        val jsApi = api.substringBefore('?').endsWith(".js", true) || site.optString("engine")=="js" || site.optString("_jsSource").isNotBlank()
        if (type != 3 && !api.startsWith("csp_") && !jsApi) return
        if (jsApi) { js = JsHost(this, EngineRules.resolve(base,api)); js!!.init(ext()); return }
        val jar = site.optString("jar").ifBlank { raw.optString("spider") }
        require(jar.isNotBlank()) { "No site jar or global spider specified for $key" }
        loader = loadJar(jar)
        NativeDexCompat.run(context) { initializeJar(api) }
    }

    private fun initializeJar(api: String) {
        try {
            val clz = loader!!.loadClass("com.github.catvod.spider.Init")
            PluginUiCompat.prepare(clz, context)
            clz.getMethod("init", Context::class.java).invoke(null, context.applicationContext)
        } catch (_: ClassNotFoundException) {} catch (_: NoSuchMethodException) {}
        PluginProxyCompat.prepare(loader!!)
        val name = if(api.startsWith("csp_")) "com.github.catvod.spider." + api.removePrefix("csp_") else api
        val loaded = loader!!.loadClass(name)
        require(Spider::class.java.isAssignableFrom(loaded)) { "$name does not implement the csp Spider ABI" }
        val value = loaded.getDeclaredConstructor().newInstance() as Spider
        spider = value
        value.siteKey = key
        value.local = com.github.catvod.utils.Local(EngineRules.digest((base+key).toByteArray()))
        value.net = com.github.catvod.net.Net(object: com.github.catvod.net.Net.Cookies {
            override fun getCookie(url: String): String = android.webkit.CookieManager.getInstance().getCookie(url).orEmpty()
            override fun setCookie(url: String,cookie: String): Boolean { android.webkit.CookieManager.getInstance().setCookie(url,cookie); return true }
        }, EngineRules.digest((base+key).toByteArray()))
        value.init(context.applicationContext, ext())
        JpjSourceCompat.prepare(value)
    }
    private fun ext(): String { val value = site.opt("ext"); return if(value==null || value==JSONObject.NULL) "" else value.toString() }

    /**
     * Downloaded DEX plugins own their persistence and open `/data/data/<pkg>/databases/tv` through
     * android.database.sqlite rather than Context.getDatabasePath(), so the parent directory has to
     * exist before Init.init runs or every plugin's cache bootstrap throws SQLiteCantOpenDatabaseException.
     * Creating it is not destructive; existing databases and their WAL files stay untouched.
     */
    private fun preparePluginDirs() {
        listOf("databases","files","cache","shared_prefs").forEach { name ->
            runCatching { File(context.applicationInfo.dataDir, name).mkdirs() }
        }
    }
    private fun localFile(url: String): File {
        val file = File(java.net.URI(url)).canonicalFile
        val roots = listOf(context.filesDir,context.cacheDir,context.codeCacheDir).map { it.canonicalFile }
        require(roots.any { file.path.startsWith(it.path+File.separator) }) { "Local engine files must be inside app-private storage" }
        return file
    }
    fun resource(url: String, max: Long = 8L*1024*1024): ByteArray = when {
        url.startsWith("assets://") -> context.assets.open(url.removePrefix("assets://")).use { it.readBytes().also { bytes -> require(bytes.size<=max) } }
        url.startsWith("file:") -> localFile(url).readBytes().also { require(it.size<=max) }
        else -> HostHttp.bytes(id,url,max)
    }
    @Synchronized fun loadJar(reference: String): DexClassLoader {
        val parts = reference.split(";md5;", limit=2)
        val url = EngineRules.resolve(base,parts[0].trim())
        var expected = parts.getOrNull(1)?.trim().orEmpty()
        if(expected.startsWith("http")) expected = resource(expected,1024).toString(Charsets.UTF_8).trim().substringBefore(' ')
        if(expected.isNotEmpty()) require(expected.matches(Regex("[a-fA-F0-9]{32}"))) { "Invalid jar MD5" }
        val name = EngineRules.digest(url.toByteArray())
        val dest = File(folder,"$name.jar")
        if(!dest.exists() || (expected.isNotEmpty() && !EngineRules.digest(dest.readBytes(),"MD5").equals(expected,true))) {
            val bytes = resource(url,64L*1024*1024)
            if(expected.isNotEmpty()) require(EngineRules.digest(bytes,"MD5").equals(expected,true)) { "Jar MD5 mismatch: $url" }
            val temp = File(folder,"$name-${UUID.randomUUID()}.tmp")
            try {
                temp.outputStream().use { output -> require(temp.setReadOnly()) { "Cannot mark dynamic code read-only" }; output.write(bytes); output.flush() }
                require(EngineRules.dex(temp)) { "Not an ART DEX archive (JVM-only JARs cannot run on Android)" }
                if(dest.exists()) require(dest.delete())
                check(temp.renameTo(dest)) { "Cannot publish verified jar" }
            } finally { temp.delete() }
        }
        require(EngineRules.dex(dest)) { "Cached JAR is not DEX" }
        require(dest.setReadOnly()) { "Android dynamic code must be read-only" }
        val libs = File(folder,"$name-native").apply { mkdirs() }
        runCatching { ZipFile(dest).use { zip ->
            val entries = zip.entries().asSequence().filter { !it.isDirectory && it.name.matches(Regex("(?:lib|jni)/[^/]+/[^/]+\\.so")) }.toList()
            if(entries.isNotEmpty()) {
                val abi = Build.SUPPORTED_ABIS.firstOrNull { candidate -> entries.any { it.name.split('/')[1]==candidate } } ?: error("JAR native library ABI not compatible with ${Build.SUPPORTED_ABIS.joinToString()}")
                entries.filter { it.name.split('/')[1]==abi }.forEach { e ->
                    val out = File(libs,e.name.substringAfterLast('/')); if(!out.exists()) zip.getInputStream(e).use { input -> out.outputStream().use { output -> input.copyTo(output) } }
                }
            }
        } }.getOrElse { if(it !is java.util.zip.ZipException) throw it }
        return DexClassLoader(dest.absolutePath,folder.absolutePath,libs.absolutePath,Spider::class.java.classLoader)
    }
    fun call(method: String, vararg args: Any): String {
        check(!closed) { "Session closed" }
        js?.let { return it.call(method,*args) }
        val s = spider ?: error("This session is for playback resolution only")
        val result = when(method) {
            "home" -> HomeResponse.merge(s.homeContent(args[0] as Boolean)) { s.homeVideoContent() }
            "category" -> s.categoryContent(args[0] as String,args[1].toString(),true,args[2] as HashMap<String,String>)
            "search" -> s.searchContent(args[0] as String,false,args[1].toString())
            "detail" -> s.detailContent(listOf(args[0] as String))
            "play" -> s.playerContent(args[0] as String,args[1] as String,raw.optJSONArray("flags")?.let { a -> (0 until a.length()).map { a.optString(it) } } ?: emptyList())
            else -> error("Unknown source method: $method")
        }
        require(result.isNotBlank()) { "Spider returned an empty $method response" }
        JSONObject(result)
        return result
    }
    fun proxy(params: Map<String,String>): Array<*> {
        js?.let { return it.proxy(params) }
        val s = spider ?: error("No plugin proxy available")
        // Prefer a concrete instance implementation, then the per-JAR static Proxy entry.
        val implementation = s.javaClass.methods.firstOrNull { it.name in listOf("proxy", "proxyLocal") && it.parameterCount==1 && it.declaringClass!=Spider::class.java }
        if(implementation!=null) return implementation.invoke(s,params) as Array<*>
        val proxyClass = loader!!.loadClass("com.github.catvod.spider.Proxy")
        val method = proxyClass.methods.firstOrNull { it.name in listOf("proxy","proxyLocal") && it.parameterCount==1 && Modifier.isStatic(it.modifiers) } ?: error("JAR has no proxy entry")
        return method.invoke(null,params) as Array<*>
    }
    fun parser(parser: JSONObject, flag: String, url: String): JSONObject {
        val dex = loader ?: raw.optString("spider").takeIf { it.isNotBlank() }?.let { loadJar(it).also { loaded -> loader=loaded } } ?: error("Parser type 2/3 requires a configured DEX jar")
        val type=parser.optInt("type")
        val key=parser.optString("url").removePrefix("csp_")
        val clz=dex.loadClass("com.github.catvod.parser."+(if(type==2) "Json" else "Mix")+key)
        val all=raw.optJSONArray("parses") ?: org.json.JSONArray()
        val result=if(type==2) {
            val values=java.util.LinkedHashMap<String,String>()
            for(i in 0 until all.length()) all.optJSONObject(i)?.let { p -> if(p.optInt("type")==1) values[p.optString("name")]=p.optString("url") }
            clz.getMethod("parse",java.util.LinkedHashMap::class.java,String::class.java).invoke(null,values,url)
        } else {
            val values=java.util.LinkedHashMap<String,HashMap<String,String>>()
            for(i in 0 until all.length()) all.optJSONObject(i)?.let { p -> values[p.optString("name")]=hashMapOf("url" to p.optString("url"),"type" to p.optInt("type").toString(),"ext" to p.optJSONObject("ext").toString()) }
            clz.getMethod("parse",java.util.LinkedHashMap::class.java,String::class.java,String::class.java,String::class.java).invoke(null,values,parser.optString("name"),flag,url)
        }
        return if(result is JSONObject) result else JSONObject(result.toString())
    }
    fun cancel() { generation.incrementAndGet(); HostHttp.cancel(id); js?.cancel(); spider?.js?.cancel(); runCatching { spider?.net?.cancel() } }
    override fun close() { if(closed) return; closed=true; cancel(); synchronized(lock) { runCatching { spider?.closeDialog() }; runCatching { spider?.destroy() }; runCatching { spider?.net?.close() }; runCatching { spider?.js?.close() }; js?.close(); js=null; spider=null; loader=null; credentials.keys().asSequence().toList().forEach { credentials.remove(it) } } }
}
