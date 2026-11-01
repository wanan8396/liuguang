package cn.liuguang.engine

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.zip.ZipOutputStream
import java.util.zip.ZipEntry

class EngineRulesTest {
    @Test fun loopbackIsExactHostNotSubstring() {
        assertTrue(EngineRules.loopback("http://127.0.0.1:9978/proxy?do=jar"))
        assertTrue(EngineRules.loopback("http://localhost:5266/proxy?do=js"))
        assertFalse(EngineRules.loopback("https://127.0.0.1.attacker.invalid/proxy"))
        assertFalse(EngineRules.loopback("https://example.invalid/path/127.0.0.1:9978"))
    }
    @Test fun onlyDocumentedLocalRoutes() {
        assertTrue(EngineRules.localRoute("http://127.0.0.1:9978/proxy?do=jar"))
        assertTrue(EngineRules.localRoute("http://localhost:9997/?do=live"))
        assertFalse(EngineRules.localRoute("http://127.0.0.1:9978/private/file"))
        assertFalse(EngineRules.localRoute("http://10.0.0.1:9978/proxy?do=jar"))
    }
    @Test fun mediaMustHaveMediaPath() {
        assertTrue(EngineRules.media("https://example.invalid/v.m3u8?token=x"))
        assertFalse(EngineRules.media("https://example.invalid/watch?id=1"))
        assertFalse(EngineRules.media("https://example.invalid/page.html"))
    }
    @Test fun resourceResolution() {
        assertEquals("https://example.invalid/engine.png",EngineRules.resolve("https://example.invalid/a/conf.json","../engine.png"))
    }
    @Test fun knownDigests() {
        assertEquals("d41d8cd98f00b204e9800998ecf8427e",EngineRules.digest(byteArrayOf(),"MD5"))
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",EngineRules.digest("abc".toByteArray()))
    }
    @Test fun extensionDoesNotDecideDex() {
        val file=File.createTempFile("engine-fixture",".png")
        try { ZipOutputStream(file.outputStream()).use { z -> z.putNextEntry(ZipEntry("classes.dex")); z.write("dex\n035\u0000".toByteArray()); z.closeEntry() }; assertTrue(EngineRules.dex(file)) } finally { file.delete() }
    }
    @Test fun jvmOnlyJarRejected() {
        val file=File.createTempFile("engine-fixture",".jar")
        try { ZipOutputStream(file.outputStream()).use { z -> z.putNextEntry(ZipEntry("Test.class")); z.write(byteArrayOf(1,2,3)); z.closeEntry() }; assertFalse(EngineRules.dex(file)) } finally { file.delete() }
    }
    @Test fun legacyPortsRequireExplicitSupportedIntegers() {
        val site=org.json.JSONObject("""{"requiredLegacyPorts":[9997],"optionalLegacyPorts":[9978,5266,9978]}""")
        assertEquals(setOf(9997),EngineRules.legacyPortList(site,"requiredLegacyPorts"))
        assertEquals(setOf(9978,5266),EngineRules.legacyPortList(site,"optionalLegacyPorts"))
        assertTrue(EngineRules.legacyPortList(org.json.JSONObject(),"requiredLegacyPorts").isEmpty())
        for (invalid in listOf("[9998]", "[\"9997\"]", "[9997.5]", "null", "{}")) {
            try {
                EngineRules.legacyPortList(org.json.JSONObject("{\"requiredLegacyPorts\":$invalid}"),"requiredLegacyPorts")
                fail("must reject $invalid")
            } catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun parserAcceptsObjectOrArrayWithoutInventingParser() {
        assertEquals(1,PlayerResolver.parserFromJson("""{"type":1,"url":"https://one.invalid/"}""").getInt("type"))
        assertEquals("first",PlayerResolver.parserFromJson("""[{"name":"first"},{"name":"second"}]""").getString("name"))
        assertEquals(0,PlayerResolver.parserFromJson("[]").length())
        try { PlayerResolver.parserFromJson("[null]"); fail("invalid parser") } catch (_: IllegalArgumentException) { }
    }
    @Test fun htmlSelectorsAndRelativeUrls() {
        val html="<ul><li><a href='/watch/1'>one</a></li><li><a href='/watch/2'>two</a></li></ul>"
        assertEquals(2,HtmlAdapter.array(html,"ul&&li").size)
        assertEquals("one",HtmlAdapter.value(html,"li:eq(0)&&a&&Text"))
        assertEquals("https://example.invalid/watch/1",HtmlAdapter.value(html,"li:eq(0)&&a&&href","https://example.invalid/"))
    }
}
