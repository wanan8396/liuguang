package cn.liuguang.engine

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.security.MessageDigest
import java.util.zip.ZipFile
import java.io.File

object EngineRules {
    val legacyPorts = setOf(9978,9997,5266)
    fun legacyPortList(site: JSONObject, name: String): Set<Int> {
        if (!site.has(name)) return emptySet()
        val values = site.opt(name)
        require(values is JSONArray) { "$name must be an array of supported port numbers" }
        val result = LinkedHashSet<Int>()
        for (index in 0 until values.length()) {
            val value = values.opt(index)
            require(value is Number && value.toDouble() == value.toLong().toDouble() && value.toLong() in legacyPorts.map { it.toLong() }) {
                "$name[$index] must be one of ${legacyPorts.joinToString()}"
            }
            result.add((value as Number).toInt())
        }
        return result
    }
    fun loopback(url: String): Boolean = runCatching { URI(url).host?.lowercase() in setOf("127.0.0.1","localhost","::1","[::1]") }.getOrDefault(false)
    fun localRoute(url: String): Boolean = runCatching { val u=URI(url); loopback(url) && (u.path in listOf("/proxy","/proxy/","/")) && (u.rawQuery?.contains("do=")==true || u.path.startsWith("/proxy")) }.getOrDefault(false)
    fun media(url: String): Boolean = runCatching { Regex("(?i)\\.(m3u8|mp4|m4v|mpd|flv|mkv|webm|ts|m4a|mp3|aac)$").containsMatchIn(URI(url).path.orEmpty()) }.getOrDefault(false)
    fun resolve(base: String, relative: String): String = if(relative.startsWith("assets://") || relative.startsWith("file:")) relative else URI(base).resolve(relative).toString()
    fun digest(bytes: ByteArray, algo: String = "SHA-256") = MessageDigest.getInstance(algo).digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun dex(file: File): Boolean {
        val magic = file.inputStream().use { BoundedIo.read(it,8) }
        if(magic.size>=4 && magic.copyOfRange(0,4).contentEquals(byteArrayOf(100,101,120,10))) return true
        if(magic.size<2 || magic[0]!=80.toByte() || magic[1]!=75.toByte()) return false
        return runCatching { ZipFile(file).use { z -> z.entries().asSequence().any { it.name.matches(Regex("classes[0-9]*\\.dex")) } } }.getOrDefault(false)
    }
}
