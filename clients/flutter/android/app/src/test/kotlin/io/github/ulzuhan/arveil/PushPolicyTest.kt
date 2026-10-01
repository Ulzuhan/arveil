package io.github.ulzuhan.arveil

import org.junit.Assert.*
import org.junit.Test

class PushPolicyTest {
    @Test fun ownServerAndExactBoundary() {
        val server = PushPolicy.server("https://notify.example.org/arveil/")!!
        assertTrue(PushPolicy.endpoint("https://notify.example.org/arveil/up-token?up=1", server))
        for (endpoint in listOf("https://elsewhere.example.org/arveil/up-token", "https://notify.example.org/arveil-other/up-token",
            "https://notify.example.org/arveil/../private", "https://notify.example.org/arveil/%2e%2e/private",
            "https://user:password@notify.example.org/arveil/up-token", "https://notify.example.org/arveil/up-token#fragment")) {
            assertFalse(PushPolicy.endpoint(endpoint, server))
        }
    }
    @Test fun noHostedDefaultOrCleartextInRelease() {
        assertNull(PushPolicy.server("https://ntfy.sh"))
        assertNull(PushPolicy.server("https://sub.ntfy.sh"))
        assertNull(PushPolicy.server("http://127.0.0.1:2586"))
        assertNotNull(PushPolicy.server("http://127.0.0.1:2586", true))
        assertNull(PushPolicy.server("https://notify.example.org?token=secret"))
        assertFalse(PushPolicy.endpoint("https://notify.example.org/" + "a".repeat(513), "https://notify.example.org"))
    }
}
