package io.github.ndelanhese.reversedicsee

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.util.concurrent.Executors

object NativeCore {
    init { System.loadLibrary("icsee_core") }
    external fun newToken(): Long
    external fun call(token: Long, request: String): String
    external fun cancel(token: Long)
}

class CameraFailure(val code: String) : Exception(code)

/** Cancelling a screen never lets a retired completion replace its new state. */
class WorkScope {
    @Volatile private var active = true
    private val tokens = mutableSetOf<Long>()
    private val ui = Handler(Looper.getMainLooper())
    fun run(request: JSONObject, success: (Any) -> Unit, failure: (String) -> Unit) {
        if (!active) return
        val token = NativeCore.newToken()
        if (token == 0L) { failure("busy"); return }
        tokens.add(token)
        workers.execute {
            val result = runCatching {
                val response = JSONObject(NativeCore.call(token, request.toString()))
                if (response.has("error")) throw CameraFailure(response.getString("error"))
                response.get("ok")
            }
            ui.post {
                tokens.remove(token)
                if (active) result.fold(success) { failure((it as? CameraFailure)?.code ?: "internal") }
            }
        }
    }
    fun close() {
        active = false
        fun cancelTokens() { tokens.forEach { NativeCore.cancel(it) }; tokens.clear() }
        if (Looper.myLooper() == Looper.getMainLooper()) cancelTokens() else ui.post { cancelTokens() }
    }
    companion object { val workers = Executors.newFixedThreadPool(2) }
}
