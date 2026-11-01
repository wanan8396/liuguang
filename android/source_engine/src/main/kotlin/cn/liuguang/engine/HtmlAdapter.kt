package cn.liuguang.engine

import org.jsoup.Jsoup
import org.jsoup.nodes.Element

object HtmlAdapter {
    private fun select(html: String,rule: String): List<Element> {
        var nodes=listOf(Jsoup.parse(html) as Element)
        rule.split("&&").filter { it.isNotBlank() }.forEach { selector -> nodes=nodes.flatMap { it.select(selector.trim()) } }
        return nodes
    }
    fun array(html: String,rule: String): List<String> = select(html,rule).map { it.outerHtml() }
    fun value(html: String,rule: String,base: String=""): String {
        val parts=rule.split("&&"); val attribute=parts.last().trim()
        val node=select(html,parts.dropLast(1).joinToString("&&")).firstOrNull() ?: return ""
        val result=when(attribute.lowercase()) { "text" -> node.text(); "html" -> node.html(); "outerhtml" -> node.outerHtml(); else -> node.attr(attribute) }
        return if(base.isNotBlank() && attribute.lowercase() in listOf("href","src","data-src","url","poster") && result.isNotBlank() && !result.startsWith("javascript:")) runCatching { EngineRules.resolve(base,result) }.getOrDefault(result) else result
    }
}
