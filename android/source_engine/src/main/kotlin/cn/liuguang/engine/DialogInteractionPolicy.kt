package cn.liuguang.engine

/**
 * Dialogs default to denied. Only the synchronous detail/play/resolve call on
 * the invoking worker is permitted; open/initialize, home, category, search,
 * fetchLocal and cleanup are not. This is not inherited by plugin-created
 * threads or asynchronous work, even when started by an interactive call.
 * Scopes restore their predecessor on failure and when executor threads reuse.
 */
internal object DialogInteractionPolicy {
    private val permission = ThreadLocal<Boolean>()

    fun isAllowed(): Boolean = permission.get() == true

    fun <T> withPermission(allowed: Boolean, action: () -> T): T {
        val previous = permission.get()
        permission.set(allowed)
        try { return action() } finally {
            if (previous == null) permission.remove() else permission.set(previous)
        }
    }
}
