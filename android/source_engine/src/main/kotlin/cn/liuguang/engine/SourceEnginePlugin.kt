package cn.liuguang.engine

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import org.json.JSONObject
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

class SourceEnginePlugin private constructor(private val activity: Activity,private val detach: () -> Unit): SourceEngineApi,AutoCloseable {
    private val lifecycle=EngineLifecycle<EngineSession>()
    private val sessions=lifecycle.sessions
    private val jobs=ConcurrentHashMap<String,MutableSet<FutureTask<Unit>>>()
    // Source calls block on network/plugin I/O. Match the UI default fan-out
    // instead of silently serializing aggregate search behind four workers.
    // Keep one owned executor so jobs, cancel, cleanup and shutdown retain
    // their existing lifecycle and per-session locking guarantees.
    private val executor=Executors.newFixedThreadPool(16)
    private val main=Handler(Looper.getMainLooper())
    private val proxy=LocalProxy(lifecycle)
    private val sniffer=WebSniffer(activity)
    private val resolver=PlayerResolver(proxy,sniffer)
    private val closed=AtomicBoolean()
    private val dialogs=PluginDialogHost(activity)
    companion object {
        private val registrationLock=Any()
        private var active: SourceEnginePlugin?=null

        private fun activate(activity: Activity, install: (SourceEnginePlugin) -> Unit, detach: () -> Unit): SourceEnginePlugin = synchronized(registrationLock) {
            active?.close()
            val plugin=SourceEnginePlugin(activity,detach)
            active=plugin
            try {
                com.github.catvod.Runtime.set(activity.applicationContext)
                com.github.catvod.Runtime.bindActivity(activity)
                com.github.catvod.Runtime.setDialog { options,action ->
                    // Capture on the plugin calling thread, before posting anything to main.
                    if(DialogInteractionPolicy.isAllowed()) plugin.dialogs.show(options,action)
                    else CompletableFuture.completedFuture(PluginDialogHost.CANCEL_JSON)
                }
                install(plugin)
                plugin
            } catch (error: Throwable) {
                plugin.close()
                throw error
            }
        }
        @JvmStatic fun register(engine: FlutterEngine,activity: Activity): SourceEnginePlugin =
            activate(activity, { SourceEngineApi.setUp(engine.dartExecutor.binaryMessenger,it) }, { SourceEngineApi.setUp(engine.dartExecutor.binaryMessenger,null) })

        // Exercises the same plugin and openSession path without starting a Flutter engine.
        internal fun createForTesting(activity: Activity): SourceEnginePlugin = activate(activity, {}, {})
    }
    private fun error(error: Throwable): FlutterError {
        var e=error
        while((e is InvocationTargetException || e is ExecutionException || e is CompletionException) && e.cause!=null) e=e.cause!!
        if(e is FlutterError) return e
        val code=when(e) { is CancellationException,is InterruptedException -> "CANCELLED"; is TimeoutException -> "TIMEOUT"; is LinkageError -> "ENGINE_ABI"; is java.io.IOException -> "NETWORK"; is IllegalArgumentException -> "INVALID_SOURCE"; else -> "SOURCE_ERROR" }
        return FlutterError(code,e.message ?: e.javaClass.simpleName,mapOf("type" to e.javaClass.name))
    }
    private fun <T> submit(id: String?=null,callback: (Result<T>)->Unit,action: ()->T) {
        val completed=AtomicBoolean()
        fun deliver(result: Result<T>) { if(completed.compareAndSet(false,true)) main.post { callback(result) } }
        val task=object: FutureTask<Unit>(Callable {
            try { check(!closed.get()) { "Engine detached" }; deliver(Result.success(DialogInteractionPolicy.withPermission(false,action))) } catch(e: Throwable) { deliver(Result.failure(error(e))) }; Unit
        }) {
            override fun done() { if(isCancelled) deliver(Result.failure(FlutterError("CANCELLED","Operation cancelled"))); if(id!=null) jobs[id]?.remove(this) }
        }
        if(id!=null) jobs.computeIfAbsent(id) { ConcurrentHashMap.newKeySet() }.add(task)
        try { executor.execute(task) } catch(e: RejectedExecutionException) { if(id!=null) jobs[id]?.remove(task); deliver(Result.failure(error(e))) }
    }
    private fun session(id: String) = sessions[id] ?: throw FlutterError("SESSION_CLOSED","Source session does not exist")
    private fun source(id: String,callback: (Result<String>)->Unit,interactive: Boolean=false,action: (EngineSession)->String) {
        val s=try { session(id) } catch(e: Throwable) { callback(Result.failure(e)); return }
        val generation=s.generation.get()
        submit(id,callback) { synchronized(s.lock) { if(generation!=s.generation.get()) throw CancellationException(); val value=DialogInteractionPolicy.withPermission(interactive) { action(s) }; if(generation!=s.generation.get()) throw CancellationException(); value } }
    }
    override fun openSession(configJson: String,siteJson: String,callback: (Result<String>)->Unit) = submit(callback=callback) {
        val s=EngineSession(activity.applicationContext,JSONObject(configJson),JSONObject(siteJson))
        var tracked=false
        try {
            val required=EngineRules.legacyPortList(s.site,"requiredLegacyPorts")
            val optional=EngineRules.legacyPortList(s.site,"optionalLegacyPorts") - required
            lifecycle.begin(s.id,s)
            tracked=true
            proxy.enableLegacy(s.id,required,true)
            synchronized(s.lock) {
                check(!closed.get() && !s.closed) { "Engine detached" }
                s.initialize()
            }
            // Only explicitly requested optional ports are attempted, after plugin init has
            // had the opportunity to start any server it owns itself.
            proxy.enableLegacy(s.id,optional,false)
            lifecycle.publish(s.id)
            s.id
        } catch(e: Throwable) {
            val owned=if(tracked) lifecycle.remove(s.id) else s
            proxy.remove(s.id)
            try { owned?.close() } catch(cleanup: Throwable) { e.addSuppressed(cleanup) }
            throw e
        }
    }
    override fun home(sessionId: String,filter: Boolean,callback: (Result<String>)->Unit) = source(sessionId,callback) { it.call("home",filter) }
    override fun category(sessionId: String,tid: String,page: Long,filtersJson: String,callback: (Result<String>)->Unit) = source(sessionId,callback) { s -> val json=JSONObject(filtersJson); val filters=HashMap<String,String>(); json.keys().forEach { filters[it]=json.opt(it).toString() }; s.call("category",tid,page.toString(),filters) }
    override fun search(sessionId: String,keyword: String,page: Long,callback: (Result<String>)->Unit) = source(sessionId,callback) { it.call("search",keyword,page.toString()) }
    override fun detail(sessionId: String,id: String,callback: (Result<String>)->Unit) = source(sessionId,callback,true) { it.call("detail",id) }
    override fun play(sessionId: String,flag: String,id: String,callback: (Result<String>)->Unit) = source(sessionId,callback,true) { it.call("play",flag,id) }
    override fun resolve(sessionId: String,resultJson: String,parserJson: String,callback: (Result<String>)->Unit) = source(sessionId,callback,true) { resolver.resolve(it,JSONObject(resultJson),PlayerResolver.parserFromJson(parserJson)) }
    override fun fetchLocal(sessionId: String,url: String,callback: (Result<String>)->Unit) = source(sessionId,callback) { proxy.localText(it,url) }
    override fun cancel(sessionId: String,callback: (Result<Unit>)->Unit) {
        sessions[sessionId]?.cancel(); sniffer.cancel(sessionId); jobs[sessionId]?.toList()?.forEach { it.cancel(true) }; callback(Result.success(Unit))
    }
    private fun cleanup(sessions: List<EngineSession>, done: ((Throwable?) -> Unit)? = null) {
        val task=Runnable {
            var failure: Throwable?=null
            sessions.forEach { session -> runCatching { session.close() }.exceptionOrNull()?.let { if(failure==null) failure=it } }
            done?.invoke(failure)
            if(done==null && failure!=null) android.util.Log.w("SourceEngine","Session cleanup failed",failure)
        }
        try { executor.execute(task) } catch (_: RejectedExecutionException) { Thread(task,"source-engine-cleanup").start() }
    }
    override fun closeSession(sessionId: String,callback: (Result<Unit>)->Unit) {
        val s=lifecycle.remove(sessionId)
        s?.let { runCatching { it.cancel() } }; sniffer.cancel(sessionId); jobs.remove(sessionId)?.toList()?.forEach { it.cancel(true) }; proxy.remove(sessionId)
        if(s==null) callback(Result.success(Unit))
        else cleanup(listOf(s)) { failure -> main.post { callback(if(failure==null) Result.success(Unit) else Result.failure(error(failure))) } }
    }
    override fun capabilities(callback: (Result<String>)->Unit) { callback(Result.success(JSONObject().put("jar",true).put("js",Build.SUPPORTED_ABIS.any { it in listOf("arm64-v8a","armeabi-v7a") }).put("jsAbis",org.json.JSONArray(listOf("arm64-v8a","armeabi-v7a"))).put("webView",true).put("parsers",org.json.JSONArray(listOf(0,1,2,3))).put("localProxy",true).put("legacyPortDiagnostics",proxy.legacyDiagnostics()).put("upstream","FongMi/TV@5e191aaced194e5cac5668cc91908ecb65336222").toString())) }
    override fun close() = synchronized(registrationLock) {
        if(!closed.compareAndSet(false,true)) return@synchronized
        val remaining=lifecycle.shutdown()
        remaining.forEach { runCatching { it.cancel() } }
        jobs.values.forEach { tasks -> tasks.toList().forEach { it.cancel(true) } }
        jobs.clear()
        sniffer.close(); proxy.close(); dialogs.close()
        if(active===this) {
            active=null
            runCatching { detach() }
            com.github.catvod.Runtime.setDialog(null)
            com.github.catvod.Runtime.bindActivity(null)
            com.github.catvod.Proxy.setUrl(null)
        }
        cleanup(remaining)
        executor.shutdown()
    }
}
