package cn.liuguang.engine

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class DialogInteractionPolicyTest {
    @Test fun defaultNestedAndExceptionRestore() {
        assertFalse(DialogInteractionPolicy.isAllowed())
        DialogInteractionPolicy.withPermission(true) {
            assertTrue(DialogInteractionPolicy.isAllowed())
            try {
                DialogInteractionPolicy.withPermission(false) {
                    assertFalse(DialogInteractionPolicy.isAllowed())
                    throw IllegalStateException()
                }
            } catch (_: IllegalStateException) { }
            assertTrue(DialogInteractionPolicy.isAllowed())
        }
        assertFalse(DialogInteractionPolicy.isAllowed())
    }

    @Test fun concurrentAndChildThreadsAreIsolatedAndWorkersReset() {
        val pool=Executors.newFixedThreadPool(2)
        val ready=CountDownLatch(2)
        val release=CountDownLatch(1)
        try {
            val allowed=pool.submit<Boolean> {
                DialogInteractionPolicy.withPermission(true) {
                    ready.countDown(); check(release.await(5,TimeUnit.SECONDS))
                    var childAllowed=true
                    val child=Thread { childAllowed=DialogInteractionPolicy.isAllowed() }
                    child.start(); child.join()
                    DialogInteractionPolicy.isAllowed() && !childAllowed
                }
            }
            val denied=pool.submit<Boolean> {
                DialogInteractionPolicy.withPermission(false) {
                    ready.countDown(); check(release.await(5,TimeUnit.SECONDS))
                    !DialogInteractionPolicy.isAllowed()
                }
            }
            assertTrue(ready.await(5,TimeUnit.SECONDS)); release.countDown()
            assertTrue(allowed.get(5,TimeUnit.SECONDS)); assertTrue(denied.get(5,TimeUnit.SECONDS))
            val checks=(1..2).map { pool.submit<Boolean> { !DialogInteractionPolicy.isAllowed() } }
            checks.forEach { assertTrue(it.get(5,TimeUnit.SECONDS)) }
        } finally { release.countDown(); pool.shutdownNow() }
    }
}
