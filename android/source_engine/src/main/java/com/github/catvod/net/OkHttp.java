package com.github.catvod.net;
import okhttp3.*;
import java.util.Map;
import java.util.concurrent.TimeUnit;
/** Host network policy: system certificates/DNS, no permissive TLS manager. */
public final class OkHttp {
    public static OkHttpClient client() { return cn.liuguang.engine.HostHttp.INSTANCE.getClient(); }
    public static OkHttpClient client(int timeout) { return client().newBuilder().connectTimeout(timeout,TimeUnit.MILLISECONDS).readTimeout(timeout,TimeUnit.MILLISECONDS).build(); }
    public static Dns dns() { return Dns.SYSTEM; }
    public static String string(String url) { return string(url,java.util.Collections.emptyMap()); }
    public static String string(String url,Map<String,String> headers) {
        Request.Builder b=new Request.Builder().url(url).header("User-Agent","okhttp/4.9.1"); for(Map.Entry<String,String> e:headers.entrySet()) b.header(e.getKey(),e.getValue());
        try(Response r=client().newCall(b.build()).execute()){ if(!r.isSuccessful())throw new java.io.IOException("HTTP "+r.code()); return r.body()==null?"":r.body().string(); }catch(java.io.IOException e){throw new java.io.UncheckedIOException(e);}
    }
}
