package cn.liuguang.engine

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.json.JSONObject
import java.io.File

/** These tests require ART; compiling them on Windows does not count as execution. */
@RunWith(AndroidJUnit4::class)
class NativeEngineTest {
    @Test fun dexDisguisedAsPngInvokesAllSpiderMethods() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        com.github.catvod.Runtime.set(context)
        val file=File(context.filesDir,"controlled-fixture.png")
        if(file.exists()) file.delete()
        instrumentation.context.assets.open("controlled.png").use { input -> file.outputStream().use { input.copyTo(it) } }
        val digest=EngineRules.digest(file.readBytes(),"MD5")
        val config=JSONObject().put("url","https://fixture.invalid/config.json").put("raw",JSONObject().put("spider",file.toURI().toString()+";md5;"+digest))
        val site=JSONObject().put("key","controlled").put("type",3).put("api","csp_Controlled").put("ext","verified")
        EngineSession(context,config,site).use { s ->
            s.initialize()
            assertEquals("verified",JSONObject(s.call("home",true)).getString("ext"))
            assertEquals(1,JSONObject(s.call("home",true)).getJSONArray("list").length())
            assertEquals(2,JSONObject(s.call("category","1","2",hashMapOf<String,String>())).getInt("page"))
            assertEquals(3,JSONObject(s.call("search","fixture","3")).getInt("page"))
            assertEquals("one",JSONObject(s.call("detail","one")).getJSONArray("list").getJSONObject(0).getString("vod_id"))
            assertEquals("https://example.invalid/",JSONObject(s.call("play","fixture","one")).getJSONObject("header").getString("Referer"))
            assertEquals("controlled-proxy",(s.proxy(mapOf("do" to "jar"))[2] as java.io.InputStream).bufferedReader().readText())
            assertNotNull(s.spider!!.net)
            assertNotNull(s.spider!!.local)
            s.spider!!.local.set("fixture","{\"value\":1}")
            assertEquals("{\"value\":1}",s.spider!!.local.get("fixture"))
        }
        file.delete()
    }
    @Test fun wrongMd5FailsBeforeDexLoad() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val file=File(context.filesDir,"bad-md5.png")
        instrumentation.context.assets.open("controlled.png").use { input -> file.outputStream().use { input.copyTo(it) } }
        val config=JSONObject().put("url","https://fixture.invalid/").put("raw",JSONObject().put("spider",file.toURI().toString()+";md5;00000000000000000000000000000000"))
        val session=EngineSession(context,config,JSONObject().put("type",3).put("api","csp_Controlled"))
        try { session.initialize(); fail("MD5 mismatch must fail") } catch(expected: IllegalArgumentException) { assertTrue(expected.message.orEmpty().contains("MD5 mismatch")) } finally { session.close(); file.delete() }
    }
    @Test fun bundledQuickJsRunsModuleFixture() {
        org.junit.Assume.assumeTrue("QuickJS explicitly skipped for emulator CI", InstrumentationRegistry.getArguments().getString("skipQuickJs") != "true")
        org.junit.Assume.assumeTrue("QuickJS requires bundled ARM JNI", android.os.Build.SUPPORTED_ABIS.any { it in listOf("arm64-v8a","armeabi-v7a") })
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        com.github.catvod.Runtime.set(context)
        val script="export default {init(){},home(){return {class:[{type_id:'1',type_name:'JS fixture'}]};},category(t,p,f,e){return {page:Number(p),list:[],filter:e};},search(k,q,p){return {page:Number(p),list:[]};},detail(id){return {list:[{vod_id:id}]};},play(f,id){return {parse:0,url:id};}}"
        val file=File(context.filesDir,"native-fixture.js").apply { writeText(script) }
        EngineSession(context,JSONObject().put("url","https://fixture.invalid/").put("raw",JSONObject()),JSONObject().put("key","js").put("type",3).put("api",file.toURI().toString())).use { s ->
            s.initialize()
            assertEquals("JS fixture",JSONObject(s.call("home",true)).getJSONArray("class").getJSONObject(0).getString("type_name"))
            assertEquals(2,JSONObject(s.call("category","1","2",hashMapOf("year" to "2026"))).getInt("page"))
            assertEquals(3,JSONObject(s.call("search","test","3")).getInt("page"))
        }
        file.delete()
    }
}
