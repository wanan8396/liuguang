package cn.liuguang.engine

import android.app.Activity
import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.webkit.*
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Offscreen native WebView, never treats the navigation URL itself as a hit. */
class WebSniffer(private val activity: Activity): AutoCloseable {
    data class Hit(val url: String,val headers: Map<String,String>)
    private val handler=Handler(Looper.getMainLooper())
    private val views=ConcurrentHashMap<String, Pair<WebView,CompletableFuture<Hit>>>()
    fun sniff(session: EngineSession,url: String,headers: Map<String,String>): Hit {
        val result=CompletableFuture<Hit>(); val operation=session.id+"/"+java.util.UUID.randomUUID()
        handler.post {
            if(activity.isFinishing || session.closed) { result.completeExceptionally(IllegalStateException("Activity/session unavailable")); return@post }
            val web=WebView(activity)
            views[operation]=web to result
            web.settings.apply { javaScriptEnabled=true; domStorageEnabled=true; allowFileAccess=false; allowContentAccess=false; mixedContentMode=WebSettings.MIXED_CONTENT_NEVER_ALLOW; mediaPlaybackRequiresUserGesture=false; headers.entries.firstOrNull { it.key.equals("User-Agent",true) }?.let { userAgentString=it.value } }
            val ua=web.settings.userAgentString
            web.webViewClient=object: WebViewClient() {
                override fun onReceivedSslError(view: WebView,handler: SslErrorHandler,error: SslError) { handler.cancel(); result.completeExceptionally(IllegalStateException("WebView TLS validation failed: ${error.primaryError}")) }
                override fun shouldInterceptRequest(view: WebView,request: WebResourceRequest): WebResourceResponse? {
                    if(result.isDone || request.isForMainFrame) return null
                    val candidate=request.url.toString()
                    val custom=runCatching { session.spider?.isVideoFormat(candidate)==true }.getOrDefault(false)
                    if(EngineRules.media(candidate) || custom) {
                        val full=HashMap(headers); full.putAll(request.requestHeaders); if(!full.keys.any { it.equals("User-Agent",true) }) full["User-Agent"]=ua
                        CookieManager.getInstance().getCookie(candidate)?.takeIf { it.isNotBlank() }?.let { full["Cookie"]=it }
                        result.complete(Hit(candidate,full))
                    }
                    return null
                }
                override fun onPageFinished(view: WebView,url: String) {
                    // A DOM media source is accepted only when it is a distinct resource, not page URL.
                    view.evaluateJavascript("JSON.stringify(Array.from(document.querySelectorAll('video,audio,source')).map(x=>x.currentSrc||x.src).filter(Boolean))") { encoded ->
                        runCatching { val decoded=org.json.JSONTokener(encoded).nextValue().toString(); val a=org.json.JSONArray(decoded); (0 until a.length()).map { a.optString(it) }.firstOrNull { it!=url && EngineRules.media(it) }?.let { candidate -> val h=HashMap(headers); h["User-Agent"]=ua; h["Referer"]=url; CookieManager.getInstance().getCookie(candidate)?.let { h["Cookie"]=it }; result.complete(Hit(candidate,h)) } }
                    }
                }
            }
            web.loadUrl(url,headers)
            handler.postDelayed({ if(!result.isDone) result.completeExceptionally(java.util.concurrent.TimeoutException("WebView found no playable media in 25 seconds")) },25000)
        }
        try { return result.get(28,TimeUnit.SECONDS) } finally { handler.post { views.remove(operation)?.first?.let { it.stopLoading(); it.loadUrl("about:blank"); it.removeAllViews(); it.destroy() } } }
    }
    fun cancel(id: String) { handler.post { views.keys.filter { it.startsWith("$id/") }.forEach { key -> views.remove(key)?.let { (web,future) -> future.cancel(false); web.stopLoading(); web.destroy() } } } }
    override fun close() { views.keys.map { it.substringBefore('/') }.distinct().forEach(::cancel) }
}
