package io.github.ulzuhan.arveil

import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

/** Limits and digest apply to exactly the bytes written into the OS session. */
internal object UpdatePackage {
    const val MAX_BYTES = 512L * 1024 * 1024

    fun copyVerified(input: InputStream, output: OutputStream, size: Long, sha256: String) {
        require(size in 1..MAX_BYTES && sha256.matches(Regex("[0-9a-f]{64}")))
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            require(total <= size)
            digest.update(buffer, 0, count)
            output.write(buffer, 0, count)
        }
        require(total == size)
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        require(actual == sha256)
    }

    /**
     * Whether a session this app left behind should be abandoned before a new
     * attempt. SessionInfo.isSealed exists from API 26 only, and calling it on
     * API 24–25 threw NoSuchMethodError, so [sealed] is never asked below 26:
     * there every leftover session goes, since only this flow creates them.
     * From 26, a sealed session is one already committed and waiting for the
     * person, and it stays.
     */
    fun abandonLeftover(sdk: Int, sealed: () -> Boolean): Boolean = sdk < 26 || !sealed()

    fun compatible(installedId: String, installedBuild: Long, installedSigners: Set<String>,
                   candidateId: String, candidateBuild: Long, candidateSigners: Set<String>, expectedBuild: Long): Boolean =
        candidateId == installedId && candidateBuild == expectedBuild &&
            candidateBuild > installedBuild && expectedBuild <= 2100000000L &&
            installedSigners.isNotEmpty() && candidateSigners == installedSigners
}
