package com.github.catvod;
public final class Proxy {
    private static volatile String url;
    public static void setUrl(String value) { url=value; }
    public static String getUrl() { return getUrl(true); }
    public static String getUrl(boolean local) { if(url==null) throw new IllegalStateException("Proxy not started"); return url; }
}
