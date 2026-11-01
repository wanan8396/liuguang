package cn.liuguang.engine

import org.junit.Assert.*
import org.junit.Test

class DexCompatibilityTest {
    @Test fun nativeBridgeRejectedWithoutInitializingIt() {
        System.clearProperty("dexnative.fixture.initialized")
        try {
            DexCompatibility.check(javaClass.classLoader!!)
            fail("native getSpider must be rejected")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message.orEmpty().contains("native DexNative.getSpider"))
        }
        assertNull(System.getProperty("dexnative.fixture.initialized"))
    }

    @Test fun absentBridgeIsAllowed() {
        val loader = object : ClassLoader(null) {}
        DexCompatibility.check(loader)
    }
}
