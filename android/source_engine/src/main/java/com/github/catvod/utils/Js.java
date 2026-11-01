package com.github.catvod.utils;
import com.fongmi.quickjs.QuickJS;
import java.util.*;
import java.util.concurrent.*;
import org.json.JSONObject;
/** Persistent per-spider QuickJS owner with cancellation and bounded evaluations. */
public final class Js implements AutoCloseable {
    private QuickJS js;
    private final Set<CompletableFuture<String>> pending=new HashSet<>();
    private boolean closed;
    public String eval(String source) throws Exception { return eval(source,"{}"); }
    public String eval(String source,String options) throws Exception { try { return evalAsync(source,options).get(); }catch(ExecutionException e){ if(e.getCause() instanceof Exception)throw (Exception)e.getCause(); throw e; } }
    public synchronized CompletableFuture<String> evalAsync(String source,String options) {
        if(closed)throw new IllegalStateException("Script owner closed");
        if(js==null) js=new QuickJS(()->System.loadLibrary("quickjs-wrapper"));
        JSONObject settings; try{settings=new JSONObject(options);}catch(Exception e){throw new IllegalArgumentException(e);}
        long timeout=settings.optLong("timeout",15000);
        CompletableFuture<String> future=js.evaluateTimed(timeout,source,settings.optString("filename","spider-eval.js")).thenApply(v->{ if(v==null)return "null"; if(v instanceof String)return (String)v; return JSONObject.wrap(v).toString(); });
        pending.add(future); future.whenComplete((value,error)->{synchronized(Js.this){pending.remove(future);}}); return future;
    }
    public synchronized void cancel(){ if(js!=null)js.cancelPending(); for(CompletableFuture<String> f:new ArrayList<>(pending))f.cancel(true); }
    @Override public synchronized void close(){if(closed)return;closed=true;cancel();if(js!=null)js.close();js=null;}
}
