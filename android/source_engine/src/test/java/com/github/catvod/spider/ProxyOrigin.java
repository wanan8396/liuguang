package com.github.catvod.spider;

/** Minimal legacy port-discovery ABI fixture; never packaged in the app. */
public final class ProxyOrigin {
    public static final int UNUSED = 0;
    public static int port = -1;
    public static boolean broken = false;

    public static String getUrl() {
        if (broken) throw new IllegalStateException("Fixture getter failure");
        return "http://127.0.0.1:" + port + "/proxy";
    }
}
