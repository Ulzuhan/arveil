package io.github.ulzuhan.arveil

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test

class UpdatePackageTest {
    private val bytes = "A release package".toByteArray()
    private val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test fun copiesExactlyTheVerifiedPackage() {
        val output = ByteArrayOutputStream()
        UpdatePackage.copyVerified(ByteArrayInputStream(bytes), output, bytes.size.toLong(), digest)
        assertArrayEquals(bytes, output.toByteArray())
    }

    @Test fun rejectsTamperingTruncationExtraBytesAndUnboundedSizes() {
        for ((input, size, hash) in listOf(
            Triple(bytes.copyOf(bytes.size - 1), bytes.size.toLong(), digest),
            Triple(bytes + 1.toByte(), bytes.size.toLong(), digest),
            Triple(bytes.reversedArray(), bytes.size.toLong(), digest),
            Triple(bytes, 0L, digest), Triple(bytes, UpdatePackage.MAX_BYTES + 1, digest),
            Triple(bytes, bytes.size.toLong(), "0".repeat(64)),
        )) assertThrows(IllegalArgumentException::class.java) {
            UpdatePackage.copyVerified(ByteArrayInputStream(input), ByteArrayOutputStream(), size, hash)
        }
    }

    @Test fun requiresSameApplicationCertificateAndStrictlyHigherExpectedBuild() {
        fun compatible(id: String = "test.app", build: Long = 18, signers: Set<String> = setOf("current"), expected: Long = 18) =
            UpdatePackage.compatible("test.app", 17, setOf("current"), id, build, signers, expected)
        assertTrue(compatible())
        assertFalse(compatible(id = "another.app"))
        assertFalse(compatible(build = 17, expected = 17))
        assertFalse(compatible(build = 16, expected = 16))
        assertFalse(compatible(build = 19))
        assertFalse(compatible(signers = setOf("attacker")))
        assertFalse(compatible(signers = emptySet()))
        assertFalse(compatible(signers = setOf("current", "unexpected")))
    }
}
