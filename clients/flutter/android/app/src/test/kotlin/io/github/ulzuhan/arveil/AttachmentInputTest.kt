package io.github.ulzuhan.arveil

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.InterruptedIOException
import org.junit.Assert.*
import org.junit.Test

class AttachmentInputTest {
    @Test fun readsEmptyAndExactLimit() {
        assertArrayEquals(byteArrayOf(), AttachmentInput.read(ByteArrayInputStream(byteArrayOf()), 3))
        val bytes = byteArrayOf(1, 2, 3)
        assertArrayEquals(bytes, AttachmentInput.read(ByteArrayInputStream(bytes), 3))
    }

    @Test fun oversizedUnknownLengthStopsAfterOneExtraByte() {
        var consumed = 0
        val input = object : InputStream() {
            override fun read(): Int { consumed++; return 1 }
        }
        assertThrows(IllegalArgumentException::class.java) { AttachmentInput.read(input, 3) }
        assertEquals(4, consumed)
    }

    @Test fun cancelledReaderNeverConsumesInput() {
        val input = ByteArrayInputStream(byteArrayOf(1, 2, 3))
        assertThrows(InterruptedIOException::class.java) {
            AttachmentInput.read(input, 3) { true }
        }
        assertEquals(3, input.available())
    }
}
