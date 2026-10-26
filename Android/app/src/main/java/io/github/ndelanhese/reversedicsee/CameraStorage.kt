package io.github.ndelanhese.reversedicsee

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class Credentials(val username: String, val password: String)

class CameraStorage(context: Context) {
    private val prefs = context.getSharedPreferences("profiles", Context.MODE_PRIVATE)
    fun load(): List<CameraProfile> = runCatching {
        val array = JSONArray(prefs.getString("cameras", "[]"))
        (0 until array.length()).map { CameraProfile.fromJson(array.getJSONObject(it)) }.filter { it.valid() }
    }.getOrDefault(emptyList())
    fun save(profiles: List<CameraProfile>) {
        require(profiles.size <= 64 && profiles.all { it.valid() })
        check(prefs.edit().putString("cameras", JSONArray(profiles.map { it.json() }).toString()).commit())
    }
}

class CredentialVault(context: Context) {
    private val prefs = context.getSharedPreferences("credentials", Context.MODE_PRIVATE)
    private val alias = "reversed-icsee-camera-credentials-v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    fun save(id: String, credentials: Credentials) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()); updateAAD(id.toByteArray()) }
        val plain = JSONObject().put("username", credentials.username).put("password", credentials.password).toString().toByteArray()
        val encrypted = try { cipher.doFinal(plain) } finally { plain.fill(0) }
        val blob = Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)
        check(prefs.edit().putString(id, blob).commit())
    }
    fun load(id: String): Credentials? {
        val blob = prefs.getString(id, null) ?: return null
        val bytes = Base64.decode(blob, Base64.NO_WRAP)
        require(bytes.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12))); updateAAD(id.toByteArray())
        }
        val plain = cipher.doFinal(bytes, 12, bytes.size - 12)
        return try { val json = JSONObject(String(plain)); Credentials(json.getString("username"), json.getString("password")) } finally { plain.fill(0) }
    }
    fun remove(id: String) { check(prefs.edit().remove(id).commit()) }
}

class PlaybackCache(context: Context) : AutoCloseable {
    val directory = File(context.cacheDir, "playback/${UUID.randomUUID()}").apply { check(mkdirs()) }
    val original = File(directory, "recording.xm")
    val movie = File(directory, "recording.mp4")
    override fun close() { directory.deleteRecursively() }
    companion object {
        fun prune(context: Context) { File(context.cacheDir, "playback").deleteRecursively() }
    }
}

fun CameraProfile.request(op: String, credentials: Credentials): JSONObject = json().put("op", op).put("username", credentials.username).put("password", credentials.password)
