package com.aaris.remoteassist.ai

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

data class AiCredential(val connectorId: String, val deviceToken: String, val clientToken: String) {
    val link: String get() = "${AiConnectorBackend.BASE_URL}/mcp/$connectorId/$clientToken"
}

/** Both the link capability and device credential are encrypted with a non-exportable key. */
class AiConnectorStore(context: Context) {
    private val prefs = context.getSharedPreferences("ai_connector", Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun load(): AiCredential? {
        val encoded = prefs.getString("credential", null) ?: return null
        val bytes = Base64.decode(encoded, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        val json = JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        return AiCredential(json.getString("id"), json.getString("device"), json.getString("client"))
    }
    fun rotateLink(): AiCredential {
        val previous = load()
        return AiCredential(previous?.connectorId ?: token(), previous?.deviceToken ?: token(), token()).also(::save)
    }
    fun getOrCreate(): AiCredential = load() ?: rotateLink()
    private fun save(value: AiCredential) {
        val json = JSONObject().put("id", value.connectorId).put("device", value.deviceToken).put("client", value.clientToken)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val encrypted = cipher.doFinal(json.toString().toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString("credential", Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)).commit())
    }
    companion object {
        private const val ALIAS = "aaris-ai-connector-v1"
        private fun token(): String = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    }
}
