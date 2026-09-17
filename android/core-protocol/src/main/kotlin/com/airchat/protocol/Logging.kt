package com.airchat.protocol

/**
 * Minimal logging seam so the protocol core stays free of Android and Kotlin-logging deps.
 * Platform modules (core-ble / app) install a real implementation; tests use [NOOP].
 */
interface AirChatLogger {
    fun log(tag: String, message: String)

    companion object {
        val NOOP: AirChatLogger = object : AirChatLogger {
            override fun log(tag: String, message: String) = Unit
        }
    }
}

/** In-memory logger used by tests and the debug UI. */
class BufferLogger(private val capacity: Int = 500) : AirChatLogger {
    private val entries = ArrayDeque<String>()

    override fun log(tag: String, message: String) {
        entries.addLast("$tag: $message")
        while (entries.size > capacity) entries.removeFirst()
    }

    fun snapshot(): List<String> = entries.toList()

    fun clear() = entries.clear()
}

/** A logger that forwards to a platform sink while also keeping a bounded in-memory tail. */
class FanOutLogger(private vararg val sinks: AirChatLogger) : AirChatLogger {
    override fun log(tag: String, message: String) {
        for (sink in sinks) sink.log(tag, message)
    }
}
