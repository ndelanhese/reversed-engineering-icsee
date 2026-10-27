package io.github.ndelanhese.reversedicsee

/** Owns a picker-created destination even after its screen callbacks are retired. */
class PendingExport(val cache: PlaybackCache, private val deleteDestination: () -> Unit) : AutoCloseable {
    val scope = WorkScope()
    private val state = java.util.concurrent.atomic.AtomicInteger(0)
    fun committed() {
        scope.close()
        if (state.compareAndSet(0, 1)) cache.close()
    }
    override fun close() {
        scope.close()
        if (state.compareAndSet(0, 2)) {
            try { runCatching { deleteDestination() } } finally { cache.close() }
        }
    }
}
