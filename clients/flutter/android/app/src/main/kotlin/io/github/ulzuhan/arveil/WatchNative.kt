package io.github.ulzuhan.arveil

/** The Rust side of the activity service (ADR-014). It waits on the relay
 * with a watch-only key and reports events; it opens no profile and reads
 * no message. Implemented in arveil-flutter's `android` module. */
object WatchNative {
    init { System.loadLibrary("arveil_flutter") }

    const val STOPPED = 0
    const val REFUSED = 1
    const val INVALID = 2

    const val LISTENING = 0
    const val ACTIVITY = 1
    const val DISCONNECTED = 2

    fun interface Listener { fun onEvent(event: Int): Boolean }

    /** The generation the next [run] waits for; [stop] moves past it. */
    @JvmStatic external fun reserve(): Long
    @JvmStatic external fun stop()
    /** Blocks until stopped, refused, or [Listener.onEvent] returns false. */
    @JvmStatic external fun run(generation: Long, credentials: ByteArray, keepaliveSeconds: Int, listener: Listener): Int
}
