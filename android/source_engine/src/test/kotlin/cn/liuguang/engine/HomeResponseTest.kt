package cn.liuguang.engine

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HomeResponseTest {
    @Test fun emptyListStillLoadsHomeVideosAndKeepsCategories() {
        for (list in listOf("", ",\"list\":[]")) {
            val result = JSONObject(HomeResponse.merge("""{"class":[{"type_id":"1"}]$list}""") {
                """{"list":[{"vod_id":"video"}]}"""
            })
            assertEquals("video", result.getJSONArray("list").getJSONObject(0).getString("vod_id"))
            assertEquals("1", result.getJSONArray("class").getJSONObject(0).getString("type_id"))
        }
    }

    @Test fun populatedHomeDoesNotRequestVideosAgain() {
        val result = JSONObject(HomeResponse.merge("""{"list":[{"vod_id":"existing"}]}""") { error("unexpected request") })
        assertEquals("existing", result.getJSONArray("list").getJSONObject(0).getString("vod_id"))
    }

    @Test fun videoOnlySpiderCanLeaveHomeContentBlank() {
        val result = JSONObject(HomeResponse.merge("") { """{"list":[{"vod_id":"video"}]}""" })
        assertEquals(1, result.getJSONArray("list").length())
    }

    @Test fun recommendationFailureKeepsCategoriesButCannotMaskCompleteFailure() {
        val result = JSONObject(HomeResponse.merge("""{"class":[{"type_id":"1"}],"list":[]}""") {
            throw java.io.IOException("recommendation endpoint unavailable")
        })
        assertEquals(1, result.getJSONArray("class").length())
        try {
            HomeResponse.merge("{}") { throw java.io.IOException("no content") }
            fail("Complete failure must remain visible")
        } catch (failure: java.io.IOException) { assertEquals("no content", failure.message) }
    }
}
