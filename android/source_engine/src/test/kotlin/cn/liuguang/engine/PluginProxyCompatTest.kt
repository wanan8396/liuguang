package cn.liuguang.engine

import com.github.catvod.Proxy
import com.github.catvod.spider.ProxyOrigin
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class PluginProxyCompatTest {
    @Before fun prepare() { ProxyOrigin.port = -1; ProxyOrigin.broken = false; Proxy.setUrl(null) }
    @After fun cleanup() { prepare() }

    @Test fun uninitializedPluginUsesHostPortAndKeepsDirectMediaRoute() {
        assertFalse(EngineRules.loopback(ProxyOrigin.getUrl()))
        Proxy.setUrl("http://127.0.0.1:45157/proxy")
        PluginProxyCompat.prepare(javaClass.classLoader!!)
        assertEquals("http://127.0.0.1:45157/proxy", ProxyOrigin.getUrl())
        assertTrue(EngineRules.loopback(ProxyOrigin.getUrl()))
        assertTrue(EngineRules.localRoute(ProxyOrigin.getUrl() + "?do=m3u8&url=https%3A%2F%2Fexample.invalid%2Fv.m3u8"))
    }

    @Test fun existingPluginPortIsPreserved() {
        ProxyOrigin.port = 9997
        Proxy.setUrl("http://127.0.0.1:45157/proxy")
        PluginProxyCompat.prepare(javaClass.classLoader!!)
        assertEquals(9997, ProxyOrigin.port)
    }

    @Test fun failedGetterRollsBackPortAndInvalidHostDoesNotBind() {
        Proxy.setUrl("http://127.0.0.1:45157/proxy")
        ProxyOrigin.broken = true
        PluginProxyCompat.prepare(javaClass.classLoader!!)
        assertEquals(-1, ProxyOrigin.port)
        ProxyOrigin.broken = false
        Proxy.setUrl("https://example.invalid:45157/proxy")
        PluginProxyCompat.prepare(javaClass.classLoader!!)
        assertEquals(-1, ProxyOrigin.port)
    }
}
