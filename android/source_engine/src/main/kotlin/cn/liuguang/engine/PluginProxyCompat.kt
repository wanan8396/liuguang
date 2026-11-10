package cn.liuguang.engine

import java.lang.reflect.Modifier
import java.net.URI

/** Supplies the host's dynamic port to plugins that otherwise scan a fixed port range. */
internal object PluginProxyCompat {
    fun prepare(loader: ClassLoader) {
        val host = runCatching { URI(com.github.catvod.Proxy.getUrl()) }.getOrNull() ?: return
        if (host.host != "127.0.0.1" || host.port !in 9978..65535) return
        val inner = runCatching {
            loader.loadClass("com.github.catvod.spider.Init").getMethod("loader").invoke(null) as? ClassLoader
        }.getOrNull() ?: loader
        runCatching {
            val cls = inner.loadClass("com.github.catvod.spider.ProxyOrigin")
            val getter = cls.getMethod("getUrl")
            if (!Modifier.isStatic(getter.modifiers) || getter.returnType != String::class.java) return
            // This ABI has one mutable static int: the discovered port, initially -1.
            val port = cls.declaredFields.singleOrNull {
                it.type == Int::class.javaPrimitiveType && Modifier.isStatic(it.modifiers) && !Modifier.isFinal(it.modifiers)
            } ?: return
            port.isAccessible = true
            if (port.getInt(null) != -1) return
            port.setInt(null, host.port)
            val verified = runCatching { getter.invoke(null) == host.toString() }.getOrDefault(false)
            if (!verified) port.setInt(null, -1)
        }
    }
}
