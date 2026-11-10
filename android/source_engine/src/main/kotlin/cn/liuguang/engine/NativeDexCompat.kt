package cn.liuguang.engine

import android.content.Context
import android.os.Build

/** Runs legacy JNI DEX factories with read-only app-private DEX files on Android 14+. */
internal object NativeDexCompat {
    init { System.loadLibrary("liuguang_dex_compat") }

    // The native scope and JNIEnv table are thread-local. A plugin waiting for
    // its own resources must not hold a process-wide lock over every other JAR.
    fun run(context: Context, action: Runnable) {
        if (Build.VERSION.SDK_INT >= 34) runScoped(context.applicationInfo.dataDir, action)
        else action.run()
    }

    @JvmStatic private external fun runScoped(dataDir: String, action: Runnable)
}
