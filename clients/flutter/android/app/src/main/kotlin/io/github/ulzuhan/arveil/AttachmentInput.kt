package io.github.ulzuhan.arveil

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.InterruptedIOException

internal object AttachmentInput {
    const val MAX_BYTES = 25 * 1024 * 1024 - 16

    // The provider's declared size is only a hint. Bound the actual stream too.
    fun read(input: InputStream, limit: Int = MAX_BYTES, cancelled: () -> Boolean = { false }): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            if (cancelled()) throw InterruptedIOException()
            val count = input.read(buffer, 0, minOf(buffer.size, limit - output.size() + 1))
            if (count == -1) return output.toByteArray()
            require(count <= limit - output.size()) { "Attachment exceeds size limit" }
            output.write(buffer, 0, count)
        }
    }
}
