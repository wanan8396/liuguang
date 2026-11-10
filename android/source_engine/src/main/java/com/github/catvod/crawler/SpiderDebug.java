package com.github.catvod.crawler;

/** Retains the plugin ABI without collecting or printing source data. */
public class SpiderDebug {
    public static void log(Throwable th) {}
    public static void log(String msg) {}
    public static void log(String tag, String msg, Object... args) {}
}
