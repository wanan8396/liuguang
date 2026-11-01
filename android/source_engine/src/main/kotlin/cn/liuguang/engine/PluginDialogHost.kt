package cn.liuguang.engine

import android.app.Activity
import android.app.AlertDialog
import android.os.Handler
import android.os.Looper
import android.widget.EditText
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.function.Function

/** Minimal foreground text/input/select dialogs; never grants permissions or installs SDKs. */
class PluginDialogHost(private val activity: Activity): AutoCloseable {
    private val main=Handler(Looper.getMainLooper())
    private val active=ConcurrentHashMap<CompletableFuture<String>,AlertDialog>()
    fun show(options: String,action: Function<String,CompletableFuture<String>>?): CompletableFuture<String> {
        val future=CompletableFuture<String>()
        main.post {
            try {
                check(!activity.isFinishing) { "No foreground activity" }
                val o=JSONObject(options)
                val input=EditText(activity).apply { setText(o.optString("value")); hint=o.optString("hint") }
                val b=AlertDialog.Builder(activity).setTitle(o.optString("title","源插件")).setMessage(o.optString("message",o.optString("content")))
                if(o.optString("type") in listOf("input","edit")) b.setView(input)
                val items=o.optJSONArray("items")
                if(items!=null) b.setItems(Array(items.length()) { items.optString(it) }) { _,index -> future.complete(JSONObject().put("action","select").put("index",index).put("value",items.opt(index)).toString()) }
                b.setPositiveButton(o.optString("positive","确定")) { _,_ ->
                    val event=JSONObject().put("action","confirm").put("value",input.text.toString()).toString()
                    if(action==null) future.complete(event) else action.apply(event).whenComplete { value,error -> if(error!=null) future.completeExceptionally(error) else future.complete(value ?: event) }
                }
                b.setNegativeButton(o.optString("negative","取消")) { _,_ -> future.complete(JSONObject().put("action","cancel").toString()) }
                b.setOnCancelListener { future.complete(JSONObject().put("action","cancel").toString()) }
                val dialog=b.create(); active[future]=dialog
                future.whenComplete { _,_ -> main.post { active.remove(future)?.dismiss() } }
                dialog.show()
            } catch(e: Throwable) { future.completeExceptionally(e) }
        }
        return future
    }
    override fun close() { active.keys.toList().forEach { it.cancel(false) }; main.post { active.values.forEach { it.dismiss() }; active.clear() } }
}
