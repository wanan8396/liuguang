package cn.liuguang.engine

import org.json.JSONObject

internal object HomeResponse {
    fun merge(content: String, videos: () -> String): String {
        val home = if (content.isBlank()) JSONObject() else JSONObject(content)
        if ((home.optJSONArray("list")?.length() ?: 0) == 0) {
            val video = try { videos() } catch (failure: Exception) {
                // Home videos are optional when categories are available. Let
                // the host load a category instead of losing all navigation.
                if ((home.optJSONArray("class")?.length() ?: 0) == 0) throw failure
                ""
            }
            if (video.isNotBlank()) JSONObject(video).optJSONArray("list")?.let { home.put("list", it) }
        }
        return home.toString()
    }
}
