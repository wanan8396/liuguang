package cn.liuguang.engine

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class PlaybackUrlTest {
    @Test fun qualityListUsesFirstUrlAndPreservesSignedQuery() {
        val url = "https://video.example/test.mp4?timestamp=1794302212&sign=abc%2B123"
        val choices = JSONArray().put("1080P").put(url).put("720P").put("https://video.example/720.mp4")
        assertEquals(url, PlayerResolver.playbackUrl(choices))
    }

    @Test fun scalarPluginUrlRemainsUnchanged() {
        val url = "http://127.0.0.1:9978/proxy?do=m3u8&url=https%3A%2F%2Fexample.test%2Fa.m3u8"
        assertEquals(url, PlayerResolver.playbackUrl(url))
    }

    @Test fun malformedQualityListFailsBeforeWebSniffing() {
        for (choices in listOf(JSONArray(), JSONArray().put("1080P"), JSONArray().put("1080P").put(4), JSONArray().put("1080P").put("file:///private/data"))) {
            assertThrows(IllegalArgumentException::class.java) { PlayerResolver.playbackUrl(choices) }
        }
    }

    @Test fun legacyHlsWrapperUsesHostTransportAndPreservesQuery() {
        val url = "https://cdn.example/video.m3u8"
        assertEquals(url, EngineRules.legacyHlsTarget("http://127.0.0.1:9997/m3u8?url=$url"))
        val signed = "$url?sign=a%2Bb&expires=123"
        val encoded = java.net.URLEncoder.encode(signed, "UTF-8")
        assertEquals(signed, EngineRules.legacyHlsTarget("http://localhost:9997/m3u8?url=$encoded"))
    }

    @Test fun unrelatedLocalRoutesRemainRejected() {
        assertNull(EngineRules.legacyHlsTarget("http://127.0.0.1:1234/m3u8?url=https://cdn.example/v.m3u8"))
        assertNull(EngineRules.legacyHlsTarget("http://127.0.0.1:9997/private?url=https://cdn.example/v.m3u8"))
        for (url in listOf("file:///private/a.m3u8", "http://127.0.0.1:8080/a.m3u8", "https://cdn.example/not-a-playlist")) {
            assertThrows(IllegalArgumentException::class.java) {
                EngineRules.legacyHlsTarget("http://127.0.0.1:9997/m3u8?url=${java.net.URLEncoder.encode(url, "UTF-8")}")
            }
        }
    }
}
