package cn.liuguang.engine

import android.app.Activity
import android.app.AlertDialog
import android.os.Handler
import android.os.Looper
import android.widget.EditText
import android.widget.TextView
import android.widget.FrameLayout
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.view.ViewGroup
import android.view.WindowManager
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.function.Function

/** Foreground text/input/select dialogs with the same spacing and rounded surfaces as the app. */
class PluginDialogHost(private val activity: Activity): AutoCloseable {
    private val main=Handler(Looper.getMainLooper())
    private val active=ConcurrentHashMap<CompletableFuture<String>,AlertDialog>()
    fun show(options: String,action: Function<String,CompletableFuture<String>>?): CompletableFuture<String> {
        val future=CompletableFuture<String>()
        main.post {
            try {
                check(!activity.isFinishing) { "No foreground activity" }
                val o=JSONObject(options)
                val dark=activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
                val surface=Color.parseColor(if(dark) "#17212E" else "#FFFFFF")
                val text=Color.parseColor(if(dark) "#ECF2FA" else "#172334")
                val muted=Color.parseColor(if(dark) "#ADBACC" else "#637185")
                val primary=Color.parseColor(if(dark) "#99C9FF" else "#2869AF")
                val soft=Color.parseColor(if(dark) "#25364A" else "#EFF5FD")
                val input=EditText(activity).apply {
                    setText(o.optString("value")); hint=o.optString("hint")
                    setTextColor(text); setHintTextColor(muted); textSize=15f
                    background=rounded(soft,14); setPadding(dp(16),dp(12),dp(16),dp(12))
                }
                val heading=TextView(activity).apply {
                    this.text=o.optString("title","源插件"); textSize=20f; setTextColor(text)
                    setTypeface(typeface,Typeface.BOLD); setPadding(dp(24),dp(26),dp(24),dp(12))
                }
                val b=AlertDialog.Builder(activity).setCustomTitle(heading).setMessage(o.optString("message",o.optString("content")))
                if(o.optString("type") in listOf("input","edit")) b.setView(FrameLayout(activity).apply {
                    setPadding(dp(24),dp(8),dp(24),dp(8))
                    addView(input,FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT))
                })
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
                dialog.window?.apply {
                    setBackgroundDrawable(rounded(surface,26))
                    setDimAmount(.42f)
                    setLayout(minOf(activity.resources.displayMetrics.widthPixels-dp(40),dp(420)),WindowManager.LayoutParams.WRAP_CONTENT)
                }
                dialog.findViewById<TextView>(android.R.id.message)?.apply {
                    setTextColor(muted); textSize=14f; setLineSpacing(dp(4).toFloat(),1f)
                }
                for (which in listOf(AlertDialog.BUTTON_NEGATIVE,AlertDialog.BUTTON_POSITIVE)) {
                    dialog.getButton(which)?.apply {
                        isAllCaps=false; textSize=14f; setTypeface(typeface,Typeface.BOLD)
                        minimumHeight=dp(46); minHeight=dp(46)
                        setPadding(dp(22),dp(10),dp(22),dp(10))
                        val positive=which==AlertDialog.BUTTON_POSITIVE
                        setTextColor(if(positive && !dark) Color.WHITE else if(positive) Color.parseColor("#123C66") else primary)
                        background=rounded(if(positive) primary else soft,13)
                        backgroundTintList=ColorStateList.valueOf(if(positive) primary else soft)
                        (layoutParams as? ViewGroup.MarginLayoutParams)?.let { params -> params.setMargins(dp(6),dp(8),dp(6),dp(14)); layoutParams=params }
                    }
                }
            } catch(e: Throwable) { future.completeExceptionally(e) }
        }
        return future
    }
    private fun dp(value: Int)=(value*activity.resources.displayMetrics.density).toInt()
    private fun rounded(color: Int,radius: Int)=GradientDrawable().apply { setColor(color); cornerRadius=dp(radius).toFloat() }
    override fun close() { active.keys.toList().forEach { it.cancel(false) }; main.post { active.values.forEach { it.dismiss() }; active.clear() } }
}
