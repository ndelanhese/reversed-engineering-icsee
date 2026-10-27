package io.github.ndelanhese.reversedicsee

import org.json.JSONObject
import java.util.UUID

data class CameraProfile(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val host: String,
    val port: Int = 554,
    val controlPort: Int = 34567,
    val onvifPort: Int = 8899,
    val channel: Int = 1,
    val substream: Boolean = false,
) {
    fun valid(): Boolean = name.isNotBlank() && name.length <= 120 &&
        host.length in 1..253 && host.first().isLetterOrDigit() && host.all { it.isLetterOrDigit() && it.code < 128 || it in ".-:" } &&
        listOf(port, controlPort, onvifPort).all { it in 1..65535 } && channel in 1..64
    fun json(): JSONObject = JSONObject().put("id", id).put("name", name).put("host", host)
        .put("port", port).put("controlPort", controlPort).put("onvifPort", onvifPort)
        .put("channel", channel).put("substream", substream)
    companion object {
        fun fromDiscovery(value: JSONObject): CameraProfile {
            val camera = CameraProfile(name = value.getString("name"), host = value.getString("host"), port = value.getInt("port"), controlPort = value.getInt("controlPort"), onvifPort = value.getInt("onvifPort"), substream = true)
            val octets = camera.host.split(".")
            require(camera.valid() && octets.size == 4 && octets.all { it.toIntOrNull() in 0..255 })
            return camera
        }
        fun fromJson(value: JSONObject): CameraProfile = CameraProfile(
            id = value.getString("id"), name = value.getString("name"), host = value.getString("host"),
            port = value.optInt("port", 554), controlPort = value.optInt("controlPort", 34567),
            onvifPort = value.optInt("onvifPort", 8899), channel = value.optInt("channel", 1), substream = value.optBoolean("substream"),
        )
    }
}
