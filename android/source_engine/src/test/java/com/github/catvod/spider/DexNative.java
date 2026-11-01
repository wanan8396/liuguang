package com.github.catvod.spider;
public class DexNative {
    static { System.setProperty("dexnative.fixture.initialized", "yes"); }
    public static native Object getSpider(Object loader, String name);
}
