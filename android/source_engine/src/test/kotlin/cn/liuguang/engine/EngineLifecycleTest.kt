package cn.liuguang.engine

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class EngineLifecycleTest {
    private class FakeListener(private val fail: Boolean = false) : EngineLifecycle.Listener {
        var starts = 0
        var stops = 0
        override fun start() { starts++; if (fail) throw IOException("busy") }
        override fun stop() { stops++ }
    }

    @Test fun optionalFailureStopsFailedListenerContinuesAndRetries() {
        val lifecycle = EngineLifecycle<Any>()
        lifecycle.begin("one", Any())
        val failed = FakeListener(true)
        val available = FakeListener()
        val failures = mutableListOf<Int>()
        lifecycle.acquirePorts("one", linkedSetOf(9978, 9997), false,
            { if (it == 9978) failed else available }, { port, _ -> failures.add(port) })
        assertEquals(listOf(9978), failures)
        assertEquals(1, failed.stops)
        assertEquals(1, available.starts)
        assertEquals(0, available.stops)
        val retry = FakeListener()
        lifecycle.acquirePorts("one", setOf(9978), false, { retry }, { _, _ -> fail("retry should succeed") })
        assertEquals(1, retry.starts)
        lifecycle.remove("one")
        assertEquals(1, available.stops)
        assertEquals(1, retry.stops)
    }

    @Test fun requiredFailureIdentifiesExactPortAndOpenCleanupReleasesEarlierLease() {
        val lifecycle = EngineLifecycle<Any>()
        lifecycle.begin("pending", Any())
        val acquired = FakeListener()
        val failed = FakeListener(true)
        try {
            lifecycle.acquirePorts("pending", linkedSetOf(9978, 5266), true,
                { if (it == 9978) acquired else failed }, { _, _ -> })
            fail("required port must fail")
        } catch (error: IllegalStateException) {
            assertTrue(error.message.orEmpty().contains("5266"))
        } finally {
            lifecycle.remove("pending")
        }
        assertEquals(1, failed.stops)
        assertEquals(1, acquired.stops)
        assertTrue(lifecycle.sessions.isEmpty())
    }

    @Test fun sharedLeaseSurvivesUntilLastSessionCloses() {
        val lifecycle = EngineLifecycle<Any>()
        lifecycle.begin("one", Any())
        lifecycle.begin("two", Any())
        val listener = FakeListener()
        lifecycle.acquirePorts("one", setOf(9978), true, { listener }, { _, _ -> fail() })
        lifecycle.acquirePorts("two", setOf(9978), true, { fail("already leased"); listener }, { _, _ -> fail() })
        lifecycle.publish("one")
        lifecycle.publish("two")
        lifecycle.remove("one")
        assertEquals(0, listener.stops)
        lifecycle.remove("two")
        assertEquals(1, listener.stops)
    }

    @Test fun shutdownRacingWithPendingStartTransfersOwnershipAndPreventsRestart() {
        val lifecycle = EngineLifecycle<Any>()
        val session = Any()
        lifecycle.begin("pending", session)
        val entered = CountDownLatch(1)
        val finishStart = CountDownLatch(1)
        val closeEntered = CountDownLatch(1)
        val stops = AtomicInteger()
        val workerError = AtomicReference<Throwable>()
        val transferred = AtomicReference<List<Any>>()
        val opener = Thread {
            try {
                lifecycle.acquirePorts("pending", setOf(9997), false, {
                    object : EngineLifecycle.Listener {
                        override fun start() { entered.countDown(); check(finishStart.await(5, TimeUnit.SECONDS)) }
                        override fun stop() { stops.incrementAndGet() }
                    }
                }, { _, _ -> fail("unexpected bind failure") })
            } catch (error: Throwable) { workerError.set(error) }
        }
        val closer = Thread { closeEntered.countDown(); transferred.set(lifecycle.shutdown()) }
        opener.start()
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            closer.start()
            assertTrue(closeEntered.await(5, TimeUnit.SECONDS))
        } finally { finishStart.countDown() }
        opener.join(5000)
        closer.join(5000)
        assertFalse(opener.isAlive)
        assertFalse(closer.isAlive)
        assertNull(workerError.get())
        assertEquals(listOf(session), transferred.get())
        assertEquals(1, stops.get())
        assertTrue(lifecycle.sessions.isEmpty())
        try { lifecycle.publish("pending"); fail("publish after shutdown") } catch (_: IllegalStateException) { }
        try { lifecycle.acquirePorts("pending", setOf(9997), false, { fail("must not restart"); FakeListener() }, { _, _ -> }); fail("start after shutdown") } catch (_: IllegalStateException) { }
        try { lifecycle.begin("new", Any()); fail("open after shutdown") } catch (_: IllegalStateException) { }
        assertTrue(lifecycle.shutdown().isEmpty())
    }
}
