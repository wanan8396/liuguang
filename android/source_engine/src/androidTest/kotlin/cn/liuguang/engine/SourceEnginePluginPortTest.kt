package cn.liuguang.engine

import android.app.Activity
import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Runs the real plugin entry point with the controlled DEX; no Flutter engine or QuickJS is started. */
@RunWith(AndroidJUnit4::class)
class SourceEnginePluginPortTest {
    private fun plugin(): SourceEnginePlugin {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext
        val activity = AtomicReference<Activity>()
        instrumentation.runOnMainSync {
            activity.set(object : Activity() {
                override fun getApplicationContext(): Context = app
            })
        }
        return SourceEnginePlugin.createForTesting(requireNotNull(activity.get()))
    }

    private fun <T> awaitResult(call: ((Result<T>) -> Unit) -> Unit): Result<T> {
        val completed = CountDownLatch(1)
        val result = AtomicReference<Result<T>?>(null)
        call { value -> result.set(value); completed.countDown() }
        assertTrue("plugin callback timed out", completed.await(30, TimeUnit.SECONDS))
        return requireNotNull(result.get())
    }

    private fun withFixture(block: (String, JSONObject) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val file = File.createTempFile("controlled-", ".png", instrumentation.targetContext.filesDir)
        try {
            instrumentation.context.assets.open("controlled.png").use { input -> file.outputStream().use { input.copyTo(it) } }
            val config = JSONObject().put("url", "https://fixture.invalid/config.json")
                .put("raw", JSONObject().put("spider", file.toURI().toString()))
            val site = JSONObject().put("key", "controlled").put("type", 3).put("api", "csp_Controlled").put("ext", "verified")
            block(config.toString(), site)
        } finally { file.delete() }
    }

    private fun withOccupied(vararg ports: Int, block: () -> Unit) {
        val sockets = ArrayList<ServerSocket>()
        try {
            ports.forEach { port ->
                val socket = ServerSocket()
                sockets.add(socket)
                socket.reuseAddress = true
                socket.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port))
            }
            block()
        } finally { sockets.forEach { it.close() } }
    }

    private fun open(plugin: SourceEnginePlugin, config: String, site: JSONObject): String =
        awaitResult<String> { plugin.openSession(config, site.toString(), it) }.getOrThrow()

    private fun closeSession(plugin: SourceEnginePlugin, id: String) {
        awaitResult<Unit> { plugin.closeSession(id, it) }.getOrThrow()
    }

    @Test fun occupiedLegacyPortsDoNotBlockControlledJarAndOptionalFailuresAreRecorded() {
        withOccupied(9978, 9997, 5266) {
            withFixture { config, site ->
                val plugin = plugin()
                try {
                    val id = open(plugin, config, site)
                    val initial = JSONObject(awaitResult<String> { plugin.capabilities(it) }.getOrThrow())
                    assertEquals(0, initial.getJSONObject("legacyPortDiagnostics").length())
                    val home = JSONObject(awaitResult<String> { plugin.home(id, true, it) }.getOrThrow())
                    assertEquals("verified", home.getString("ext"))
                    val result = JSONObject().put("url", "http://127.0.0.1:9978/proxy?do=jar").put("parse", 0)
                    for (parsers in listOf("[]", "[{\"type\":1,\"url\":\"https://parser.invalid/\"}]", "{\"type\":0}")) {
                        val resolved = JSONObject(awaitResult<String> { plugin.resolve(id, result.toString(), parsers, it) }.getOrThrow())
                        assertFalse(URI(resolved.getString("url")).port in EngineRules.legacyPorts)
                        assertEquals("controlled-proxy", awaitResult<String> { plugin.fetchLocal(id, resolved.getString("url"), it) }.getOrThrow())
                    }
                    val optionalSite = JSONObject(site.toString()).put("key", "optional")
                        .put("optionalLegacyPorts", JSONArray(listOf(9978, 9997, 5266)))
                    val optionalId = open(plugin, config, optionalSite)
                    assertEquals("verified", JSONObject(awaitResult<String> { plugin.home(optionalId, true, it) }.getOrThrow()).getString("ext"))
                    val diagnostics = JSONObject(awaitResult<String> { plugin.capabilities(it) }.getOrThrow()).getJSONObject("legacyPortDiagnostics")
                    listOf("9978", "9997", "5266").forEach { assertTrue("missing diagnostic for $it", diagnostics.has(it)) }
                    closeSession(plugin, optionalId)
                    closeSession(plugin, id)
                } finally { plugin.close() }
            }
        }
    }

    @Test fun requiredPortChecksOnlyRequestedPortAndReleasesIt() {
        withOccupied(9978, 5266) {
            withFixture { config, site ->
                val plugin = plugin()
                try {
                    val required = JSONObject(site.toString()).put("requiredLegacyPorts", JSONArray(listOf(9997)))
                    val id = open(plugin, config, required)
                    assertEquals("verified", JSONObject(awaitResult<String> { plugin.home(id, true, it) }.getOrThrow()).getString("ext"))
                    closeSession(plugin, id)
                    withOccupied(9997) { }
                    val occupied = JSONObject(site.toString()).put("requiredLegacyPorts", JSONArray(listOf(9978)))
                    val failure = awaitResult<String> { plugin.openSession(config, occupied.toString(), it) }.exceptionOrNull()
                    assertNotNull(failure)
                    assertTrue(failure!!.message.orEmpty().contains("9978"))
                } finally { plugin.close() }
            }
        }
    }

    @Test fun registeringAgainClosesOldPluginWithoutClearingNewProxy() {
        withFixture { config, site ->
            val first = plugin()
            var second: SourceEnginePlugin? = null
            try {
                open(first, config, site)
                val current = plugin()
                second = current
                val currentUrl = com.github.catvod.Proxy.getUrl()
                first.close()
                assertEquals(currentUrl, com.github.catvod.Proxy.getUrl())
                val old = awaitResult<String> { first.openSession(config, site.toString(), it) }
                assertTrue(old.isFailure)
                val id = open(current, config, site)
                assertEquals("verified", JSONObject(awaitResult<String> { current.home(id, true, it) }.getOrThrow()).getString("ext"))
                closeSession(current, id)
            } finally { first.close(); second?.close() }
        }
    }
}
