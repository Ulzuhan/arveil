package io.github.ulzuhan.arveil

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Delivery preferences/capabilities only. Never reads the profile key or DB.
 * Android excludes the app from backups; this additional Keystore key protects
 * the endpoint at rest and remains usable for a generic locked-profile hint. */
object PushStore {
    private const val alias = "arveil.notification-preferences.v1"
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "Notification key unavailable" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    @Synchronized fun read(context: Context): JSONObject {
        val saved = context.getSharedPreferences("arveil.push", Context.MODE_PRIVATE).getString("state", null)
            ?: return JSONObject()
        val bytes = Base64.decode(saved, Base64.NO_WRAP)
        check(bytes.size in 29..8192)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
    }

    @Synchronized fun update(context: Context, change: (JSONObject) -> Unit): JSONObject {
        val state = read(context)
        change(state)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true))
        val bytes = state.toString().toByteArray(Charsets.UTF_8)
        check(bytes.size <= 4096)
        val saved = Base64.encodeToString(cipher.iv + cipher.doFinal(bytes), Base64.NO_WRAP)
        check(context.getSharedPreferences("arveil.push", Context.MODE_PRIVATE).edit().putString("state", saved).commit())
        return state
    }
}
