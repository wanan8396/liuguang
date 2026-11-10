package cn.liuguang.engine

import com.github.catvod.crawler.Spider
import org.json.JSONObject
import java.lang.reflect.Modifier
import java.util.Locale
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Older JPJ plugins treat a 403 HTML page as a healthy mirror during init. */
internal object JpjSourceCompat {
    private const val discovery = "https://dns.alidns.com/resolve?name=swrdsfeiujo25sw.cc&type=TXT"
    private const val catalog = "/api/slide/list?pos_id=88"
    private val http = HostHttp.client.newBuilder()
        .connectTimeout(2, TimeUnit.SECONDS).readTimeout(2, TimeUnit.SECONDS)
        .callTimeout(3, TimeUnit.SECONDS).build()
    @Volatile private var lastHealthyBase: String? = null

    fun prepare(value: Spider) {
        val actual = when (value.javaClass.name) {
            "com.github.catvod.spider.JPJ" -> value
            "com.github.catvod.spider.JPJGuard" -> runCatching {
                value.javaClass.superclass.declaredFields.firstOrNull {
                    !Modifier.isStatic(it.modifiers) && Spider::class.java.isAssignableFrom(it.type)
                }?.apply { isAccessible = true }?.get(value) as? Spider
            }.getOrNull()
            else -> null
        } ?: return
        if (actual.javaClass.name != "com.github.catvod.spider.JPJ") return
        // Identify the endpoint by its value so an unrelated obfuscated field is never changed.
        val baseField = actual.javaClass.declaredFields.firstOrNull { field ->
            field.type == String::class.java && !Modifier.isStatic(field.modifiers) && runCatching {
                field.isAccessible = true
                (field.get(actual) as? String)?.matches(Regex("https?://fan123\\.[a-zA-Z0-9.-]+/?")) == true
            }.getOrDefault(false)
        } ?: return
        val current = (baseField.get(actual) as String).trimEnd('/')
        @Suppress("UNCHECKED_CAST")
        val headers = runCatching {
            actual.javaClass.declaredMethods.firstOrNull {
                !Modifier.isStatic(it.modifiers) && it.parameterCount == 0 && Map::class.java.isAssignableFrom(it.returnType)
            }?.apply { isAccessible = true }?.invoke(actual) as? Map<String, String>
        }.getOrNull().orEmpty()
        val remembered = lastHealthyBase
        if (remembered != null && healthy(remembered, headers)) {
            baseField.set(actual, remembered)
            return
        }
        if (current != remembered && healthy(current, headers)) {
            lastHealthyBase = current
            return
        }
        val domains = runCatching { domains(fetch(discovery, emptyMap())?.second.orEmpty()) }.getOrDefault(emptyList())
        val alternatives = domains.map { "https://fan123.$it" }.filter { it != current && it != remembered }
        val executor = Executors.newFixedThreadPool(minOf(4, alternatives.size.coerceAtLeast(1)))
        val completion = ExecutorCompletionService<String?>(executor)
        val futures = alternatives.map { base -> completion.submit(Callable { base.takeIf { healthy(it, headers) } }) }
        var selected: String? = null
        try {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(7)
            repeat(futures.size) {
                if (selected == null) {
                    val remaining = deadline - System.nanoTime()
                    if (remaining > 0) selected = completion.poll(remaining, TimeUnit.NANOSECONDS)?.get()
                }
            }
        } finally {
            futures.forEach { it.cancel(true) }
            executor.shutdownNow()
        }
        check(selected != null) { "荐片接口暂时不可用，已尝试备用域名，请稍后重试" }
        baseField.set(actual, selected)
        lastHealthyBase = selected
    }

    private fun healthy(base: String, headers: Map<String, String>): Boolean {
        val response = fetch(base + catalog, headers + ("Referer" to base)) ?: return false
        return isCatalog(response.first, response.second)
    }

    private fun fetch(url: String, headers: Map<String, String>): Pair<Int, String>? = runCatching {
        http.newCall(HostHttp.request(url, headers).build()).execute().use { response ->
            // Only the small discovery/catalog documents are needed for mirror selection.
            response.code to response.peekBody(256 * 1024).string()
        }
    }.getOrNull()

    internal fun isCatalog(status: Int, body: String): Boolean = status in 200..299 && runCatching {
        JSONObject(body).optJSONArray("data") != null
    }.getOrDefault(false)

    internal fun domains(body: String): List<String> {
        val answers = runCatching { JSONObject(body).optJSONArray("Answer") }.getOrNull() ?: return emptyList()
        val domain = Regex("(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}")
        return (0 until answers.length()).flatMap { index ->
            val answer = answers.optJSONObject(index)
            if (answer?.optInt("type") != 16) emptyList()
            else answer.optString("data").replace("\\\"", "").replace("\"", "").split(',')
        }.map { it.trim().lowercase(Locale.ROOT) }.filter { domain.matches(it) }.distinct().take(16)
    }
}
