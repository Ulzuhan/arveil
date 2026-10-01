package io.github.ulzuhan.arveil

import java.net.URI

/** This increment supports ntfy's generic, plaintext wake marker only. It is
 * deliberately not interpreted as an authenticated message or message count. */
object PushPolicy {
    val marker = "arveil-hint/v1".toByteArray(Charsets.US_ASCII)

    fun server(value: String, development: Boolean = false): String? = try {
        val u = URI(value)
        val host = u.host?.lowercase()
        if (value.length > 300 || value.any { it.code !in 33..126 } || host.isNullOrEmpty() ||
            u.rawUserInfo != null || u.rawQuery != null || u.rawFragment != null ||
            host == "ntfy.sh" || host.endsWith(".ntfy.sh") ||
            (u.scheme != "https" && !(development && u.scheme == "http" && host == "127.0.0.1")) ||
            u.normalize() != u || u.rawPath.contains('%')) null
        else u.toString().trimEnd('/')
    } catch (_: Exception) { null }

    fun endpoint(value: String, server: String, development: Boolean = false): Boolean = try {
        val base = server(server, development)?.let { URI(it) }
        val u = URI(value)
        base != null && value.length <= 512 && value.all { it.code in 33..126 } &&
            u.scheme == base.scheme && u.rawAuthority == base.rawAuthority &&
            u.rawUserInfo == null && u.rawFragment == null && u.normalize() == u &&
            u.rawPath.startsWith(base.rawPath.trimEnd('/') + "/") &&
            !u.rawPath.contains('%') && u.rawPath.length > base.rawPath.trimEnd('/').length + 1
    } catch (_: Exception) { false }
}
