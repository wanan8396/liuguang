package cn.liuguang.engine

import android.content.Context
import android.os.Build
import java.io.File
import java.lang.reflect.Modifier

/** Keep a downloaded proxy's automatic status notification quiet; its manual panel still works. */
internal object PluginUiCompat {
    fun prepare(init: Class<*>, context: Context) {
        val arch = when (Build.SUPPORTED_ABIS.firstOrNull()) {
            "arm64-v8a" -> "arm64"
            "armeabi-v7a", "armeabi" -> "arm"
            "x86_64" -> "amd64"
            else -> return
        }
        if (!downloaded(File(context.filesDir, "soproxy-android-$arch.so"))) return
        runCatching {
            // This named flag belongs to the legacy Init/SoPanel contract. Do not
            // alter generic dialog handling or another plugin's unrelated flags.
            init.classLoader!!.loadClass("com.github.catvod.spider.SoPanel")
                .getMethod("currentArch")
            val field = init.getDeclaredField("soFailNotified")
            if (field.type == Boolean::class.javaPrimitiveType && Modifier.isStatic(field.modifiers)) {
                field.isAccessible = true
                field.setBoolean(null, true)
                android.util.Log.i("LiuguangPluginUI", "Downloaded proxy: automatic SO status panel suppressed")
            }
        }
    }

    internal fun downloaded(file: File): Boolean = runCatching {
        if (!file.isFile || file.length() < 64) return@runCatching false
        file.inputStream().use { stream ->
            val header = ByteArray(4)
            stream.read(header) == 4 && header.contentEquals(byteArrayOf(0x7f, 0x45, 0x4c, 0x46))
        }
    }.getOrDefault(false)
}
