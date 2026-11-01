package com.github.catvod;
import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;
import java.lang.ref.WeakReference;
import java.util.concurrent.CompletableFuture;
import java.util.function.*;
public final class Runtime {
    private static WeakReference<Context> context=new WeakReference<>(null);
    private static Supplier<Activity> activity=()->null;
    private static Consumer<String> toast;
    private static BiFunction<String,Function<String,CompletableFuture<String>>,CompletableFuture<String>> dialog;
    public static void set(Context value) { context=new WeakReference<>(value.getApplicationContext()); }
    public static Context context() { Context c=context.get(); if(c==null)throw new IllegalStateException("Host detached"); return c; }
    public static void setActivity(Supplier<Activity> value) { activity=value==null?()->null:value; }
    public static void bindActivity(Activity value) { WeakReference<Activity> ref=new WeakReference<>(value); activity=ref::get; }
    public static Activity activity() { Activity a=activity.get(); return a==null||a.isFinishing()||a.isDestroyed()?null:a; }
    public static void setToast(Consumer<String> value) { toast=value; }
    public static void toast(String text) { if(toast!=null)toast.accept(text); else new Handler(Looper.getMainLooper()).post(()->Toast.makeText(context(),text,Toast.LENGTH_SHORT).show()); }
    public static void setDialog(BiFunction<String,Function<String,CompletableFuture<String>>,CompletableFuture<String>> value) { dialog=value; }
    public static CompletableFuture<String> dialog(String options,Function<String,CompletableFuture<String>> callback) {
        if(dialog!=null)return dialog.apply(options,callback);
        CompletableFuture<String> future=new CompletableFuture<>(); future.completeExceptionally(new IllegalStateException("No foreground plugin dialog host")); return future;
    }
}
