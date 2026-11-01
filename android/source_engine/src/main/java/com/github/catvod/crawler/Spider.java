/* SPDX-License-Identifier: GPL-3.0-or-later
 * Adapted from FongMi/TV catvod Spider, 4d7e16fa237dbea5f5f066429d31b94a5b037301.
 * Added proxy aliases and site key for mixed-generation csp jars.
 */
package com.github.catvod.crawler;

import android.content.Context;
import android.app.Activity;
import com.github.catvod.Proxy;
import java.io.ByteArrayInputStream;
import java.util.*;
import okhttp3.Dns;
import okhttp3.OkHttpClient;

public abstract class Spider {
    public String siteKey;
    public com.github.catvod.net.Net net;
    public com.github.catvod.utils.Local local;
    public final com.github.catvod.utils.Js js = new com.github.catvod.utils.Js();
    private final com.github.catvod.utils.Dialog dialog = new com.github.catvod.utils.Dialog();
    public org.json.JSONObject dialog(org.json.JSONObject options) throws Exception { return dialog.show(options,null); }
    public org.json.JSONObject dialog(org.json.JSONObject options,com.github.catvod.utils.Dialog.Callback callback) throws Exception { return dialog.show(options,callback); }
    public final void closeDialog() { dialog.close(); }
    public void init(Context context) throws Exception {}
    public void init(Context context, String extend) throws Exception { init(context); }
    public String homeContent(boolean filter) throws Exception { return ""; }
    public String homeVideoContent() throws Exception { return ""; }
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String,String> extend) throws Exception { return ""; }
    public String detailContent(List<String> ids) throws Exception { return ""; }
    public String searchContent(String key, boolean quick) throws Exception { return ""; }
    public String searchContent(String key, boolean quick, String pg) throws Exception { return searchContent(key, quick); }
    public String playerContent(String flag, String id, List<String> flags) throws Exception { return ""; }
    public String liveContent() throws Exception { return ""; }
    public String liveContent(String url) throws Exception { return liveContent(); }
    public boolean manualVideoCheck() throws Exception { return false; }
    public boolean isVideoFormat(String url) throws Exception { return false; }
    public Object[] proxyLocal(Map<String,String> params) throws Exception { return new Object[]{404,"text/plain",new ByteArrayInputStream(new byte[0])}; }
    public Object[] proxy(Map<String,String> params) throws Exception { return proxyLocal(params); }
    public void destroy() {}
    public static Dns safeDns() { return Dns.SYSTEM; }
    public static OkHttpClient client() { return cn.liuguang.engine.HostHttp.INSTANCE.getClient(); }
    public Activity getActivity() { return com.github.catvod.Runtime.activity(); }
    public String action(String action) throws Exception { return "{}"; }
    public String danmakuUrl(String id) { return danmakuUrl(siteKey,id); }
    public static String danmakuUrl(String key,String id) { return new android.net.Uri.Builder().scheme("spider").authority(key).appendPath(id).build().toString(); }
    public AutoCloseable danmaku(String id,java.util.function.Consumer<org.json.JSONObject> emit) throws Exception { throw new IllegalStateException("Spider has no live danmaku implementation"); }
    public String proxyUrl() { return proxyUrl(Collections.emptyMap()); }
    public String proxyUrl(Map<String,String> params) { return proxyUrl(params,true); }
    public String proxyUrl(Map<String,String> params, boolean local) {
        android.net.Uri.Builder b=android.net.Uri.parse(Proxy.getUrl(local)).buildUpon().appendQueryParameter("do","jar").appendQueryParameter("siteKey",siteKey);
        for(Map.Entry<String,String> e:params.entrySet()) b.appendQueryParameter(e.getKey(), e.getValue());
        return b.build().toString();
    }
}
