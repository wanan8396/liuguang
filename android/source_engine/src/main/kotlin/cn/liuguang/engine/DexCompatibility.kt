package cn.liuguang.engine

import java.lang.reflect.Modifier

/** Known unsafe JNI ABI; inspect without initializing before Init or spider construction.
 * This narrow deny rule is not a sandbox for arbitrary plugin code. */
internal object DexCompatibility {
    fun check(loader: ClassLoader) {
        val bridge = try {
            Class.forName("com.github.catvod.spider.DexNative", false, loader)
        } catch (_: ClassNotFoundException) {
            return
        } catch (e: LinkageError) {
            throw IllegalArgumentException("Cannot safely inspect plugin DexNative ABI", e)
        }
        val unsafe = try {
            bridge.declaredMethods.any { it.name == "getSpider" && Modifier.isNative(it.modifiers) }
        } catch (e: LinkageError) {
            throw IllegalArgumentException("Cannot safely inspect plugin DexNative ABI", e)
        } catch (e: SecurityException) {
            throw IllegalArgumentException("Cannot safely inspect plugin DexNative ABI", e)
        }
        require(!unsafe) { "Unsupported plugin: native DexNative.getSpider is incompatible with this host and may abort the process" }
    }
}
