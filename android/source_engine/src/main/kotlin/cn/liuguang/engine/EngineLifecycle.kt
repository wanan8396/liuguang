package cn.liuguang.engine

import java.util.concurrent.ConcurrentHashMap

/** Owns pending and published sessions and their legacy listener leases under one lock. */
internal class EngineLifecycle<S : Any> {
    internal interface Listener {
        fun start()
        fun stop()
    }

    private data class Lease(val listener: Listener, val owners: MutableSet<String>)
    internal val lock = Any()
    val sessions = ConcurrentHashMap<String, S>()
    private val pending = HashSet<String>()
    private val ports = LinkedHashMap<Int, Lease>()
    private var closed = false

    fun begin(id: String, session: S) = synchronized(lock) {
        check(!closed) { "Engine detached" }
        check(sessions.putIfAbsent(id, session) == null) { "Duplicate session" }
        pending.add(id)
        Unit
    }

    fun publish(id: String) = synchronized(lock) {
        check(!closed && sessions.containsKey(id) && pending.remove(id)) { "Engine detached or session closed" }
    }

    fun acquirePorts(id: String, requested: Set<Int>, required: Boolean,
                     create: (Int) -> Listener, failed: (Int, Exception) -> Unit) = synchronized(lock) {
        check(!closed && sessions.containsKey(id)) { "Engine detached or session closed" }
        requested.forEach { port ->
            try {
                val lease = ports[port] ?: run {
                    val listener = create(port)
                    try {
                        listener.start()
                    } catch (error: Throwable) {
                        runCatching { listener.stop() }
                        throw error
                    }
                    Lease(listener, HashSet()).also { ports[port] = it }
                }
                lease.owners.add(id)
            } catch (error: Exception) {
                failed(port, error)
                if (required) throw IllegalStateException("Required legacy port $port could not be bound: ${error.message}", error)
            }
        }
    }

    fun remove(id: String): S? = synchronized(lock) {
        pending.remove(id)
        val session = sessions.remove(id)
        val iterator = ports.entries.iterator()
        while (iterator.hasNext()) {
            val lease = iterator.next().value
            lease.owners.remove(id)
            if (lease.owners.isEmpty()) {
                iterator.remove()
                runCatching { lease.listener.stop() }
            }
        }
        session
    }

    fun stopPorts() = synchronized(lock) {
        ports.values.forEach { runCatching { it.listener.stop() } }
        ports.clear()
    }

    /** Transfers ownership of every session, including in-progress opens, to the caller. */
    fun shutdown(): List<S> = synchronized(lock) {
        if (closed) return@synchronized emptyList()
        closed = true
        val remaining = sessions.values.toList()
        sessions.clear()
        pending.clear()
        ports.values.forEach { runCatching { it.listener.stop() } }
        ports.clear()
        remaining
    }
}
