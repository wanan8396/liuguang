package cn.liuguang.engine

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.os.Build
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class NativeDexCompatTest {
    private external fun create(path: String, folder: String, parent: ClassLoader, mode: Int): ClassLoader
    private external fun rewrite(path: String, bytes: ByteArray, type: Int, mode: Int)

    @Test fun waitingPluginDoesNotBlockAnotherNativeScope() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val executor = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val slow = executor.submit { NativeDexCompat.run(context) { entered.countDown(); release.await() } }
            assertTrue(entered.await(3, java.util.concurrent.TimeUnit.SECONDS))
            val fast = executor.submit<Boolean> {
                var called = false
                NativeDexCompat.run(context) { called = true }
                called
            }
            assertTrue(fast.get(3, java.util.concurrent.TimeUnit.SECONDS))
            release.countDown()
            slow.get(3, java.util.concurrent.TimeUnit.SECONDS)
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun repeatedNativeLoadsReplaceReadOnlyDexWithoutChangingMappedInode() {
        org.junit.Assume.assumeTrue(Build.VERSION.SDK_INT >= 34)
        System.loadLibrary("liuguang_dex_compat")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val bytes = java.util.zip.ZipInputStream(instrumentation.context.assets.open("controlled.png")).use { zip ->
            var entry = zip.nextEntry
            while (entry != null && entry.name != "classes.dex") entry = zip.nextEntry
            check(entry != null)
            zip.readBytes()
        }
        for (type in 0..3) for (mode in 0..2) {
            val file = File(context.cacheDir, ".dx-reload-$type-$mode.tmp")
            file.delete()
            try {
                var previous: ClassLoader? = null
                repeat(3) {
                    NativeDexCompat.run(context) {
                        rewrite(file.path, bytes, type, mode)
                        assertTrue(file.canWrite())
                        val loaded = create(file.path, context.codeCacheDir.path, context.classLoader, mode)
                        assertFalse(file.canWrite())
                        assertEquals("com.github.catvod.spider.Controlled", loaded.loadClass("com.github.catvod.spider.Controlled").name)
                        previous?.loadClass("com.github.catvod.spider.Controlled")?.getDeclaredConstructor()?.newInstance()
                        previous = loaded
                    }
                }
            } finally { file.delete() }
        }
        val ordinary = File(context.cacheDir, "readonly-config.txt").apply { writeText("unchanged"); setReadOnly() }
        try {
            try {
                NativeDexCompat.run(context) { rewrite(ordinary.path, bytes, 0, 0) }
                fail("Read-only non-DEX data must not be removed")
            } catch (_: java.io.FileNotFoundException) { }
            assertEquals("unchanged", ordinary.readText())
        } finally { ordinary.delete() }
    }

    @Test fun nativeConstructorsLoadReadOnlyDexAndRestoreAfterException() {
        org.junit.Assume.assumeTrue(Build.VERSION.SDK_INT >= 34)
        System.loadLibrary("liuguang_dex_compat")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        fun fixture(name: String) = File(context.cacheDir, name).apply {
            delete()
            instrumentation.context.assets.open("controlled.png").use { input -> outputStream().use { input.copyTo(it) } }
        }
        for (mode in 0..2) {
            val file = fixture("native-compat-$mode.jar")
            val untouched = File(context.cacheDir, "ordinary-$mode.txt").apply { writeText("unchanged") }
            try {
                try {
                    create(file.path, context.codeCacheDir.path, context.classLoader, mode)
                    fail("The control must reject a writable DEX on Android 14+")
                } catch (_: SecurityException) { }
                NativeDexCompat.run(context) {
                    NativeDexCompat.run(context) {
                        val loaded = create(file.path, context.codeCacheDir.path, context.classLoader, mode)
                        assertEquals("com.github.catvod.spider.Controlled", loaded.loadClass("com.github.catvod.spider.Controlled").name)
                    }
                }
                assertFalse(file.canWrite())
                assertTrue(untouched.canWrite())
                try {
                    NativeDexCompat.run(context) { throw IllegalStateException("fixture") }
                    fail("Callback exception must propagate")
                } catch (failure: IllegalStateException) { assertEquals("fixture", failure.message) }
                file.delete()
                fixture(file.name)
                try {
                    create(file.path, context.codeCacheDir.path, context.classLoader, mode)
                    fail("The JNI table must be restored outside the scope")
                } catch (_: SecurityException) { }
            } finally {
                file.delete(); untouched.delete()
            }
        }
    }
}
