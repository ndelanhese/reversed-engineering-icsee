package io.github.ndelanhese.reversedicsee

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address

/** Discovery owns its multicast lock and native request only while a visible scan runs. */
class DiscoveryScreen(app: MainActivity) : CameraScreen(app) {
    private var lock: WifiManager.MulticastLock? = null
    private var searching = false
    private var launched = false
    private var cameras = emptyList<CameraProfile>()
    private var notice: String? = null

    override fun show() {
        val root = app.frame(app.getString(R.string.find_cameras))
        app.text(root, app.getString(R.string.discovery_intro))
        app.text(root, notice ?: "")
        val actions = app.row(root)
        app.button(actions, R.string.search_again) { search() }.isEnabled = !searching
        app.button(actions, R.string.stop_scan) { stop(); notice = null; show() }.isEnabled = searching
        app.button(root, R.string.add_manually) { app.editCamera() }
        val results = app.scroll(root)
        for (camera in cameras) {
            val saved = app.profiles.any { it.host.equals(camera.host, ignoreCase = true) }
            val label = "${camera.name}\n${camera.host}:${camera.onvifPort}" + if (saved) "\n${app.getString(R.string.already_added)}" else ""
            app.button(results, label) { app.editCamera(discovered = camera) }.isEnabled = !saved
        }
        if (!launched) { launched = true; search() }
    }

    private fun search() = app.network {
        stop()
        scope = WorkScope()
        val manager = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val interfaces = JSONArray()
        val seen = mutableSetOf<String>()
        for (network in manager.allNetworks) {
            val capabilities = manager.getNetworkCapabilities(network) ?: continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ||
                !(capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))) continue
            for (link in manager.getLinkProperties(network)?.linkAddresses.orEmpty()) {
                val address = link.address
                val host = address.hostAddress ?: continue
                if (address is Inet4Address && !address.isLoopbackAddress && !address.isAnyLocalAddress && !address.isMulticastAddress && seen.add(host) && interfaces.length() < 16) {
                    interfaces.put(JSONObject().put("address", host).put("prefixLength", link.prefixLength))
                }
            }
        }
        if (interfaces.length() == 0) { notice = app.getString(R.string.discovery_no_network); show(); return@network }
        val wifi = app.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        try {
            lock = wifi?.createMulticastLock("camera-discovery")?.apply { setReferenceCounted(false); acquire() }
        } catch (_: SecurityException) {
            notice = app.getString(R.string.permission_denied); show(); return@network
        }
        searching = true
        cameras = emptyList()
        notice = app.getString(R.string.discovery_scanning)
        show()
        scope.run(JSONObject().put("op", "discover").put("interfaces", interfaces), { response ->
            releaseLock()
            searching = false
            runCatching {
                val devices = (response as JSONObject).getJSONArray("devices")
                require(devices.length() <= 64)
                (0 until devices.length()).mapNotNull { index ->
                    runCatching { CameraProfile.fromDiscovery(devices.getJSONObject(index)) }.getOrNull()
                }.distinctBy { it.host }
            }.fold({ found ->
                cameras = found
                notice = if (found.isEmpty()) app.getString(R.string.discovery_empty) else app.getString(R.string.discovery_defaults)
            }, { notice = app.getString(R.string.error_invalid_response) })
            show()
        }, { code -> releaseLock(); searching = false; notice = errorMessage(app, code); show() })
    }

    private fun releaseLock() { lock?.let { if (it.isHeld) it.release() }; lock = null }
    private fun stop() { scope.close(); searching = false; releaseLock() }
    override fun pause() { super.pause(); stop(); if (notice == app.getString(R.string.discovery_scanning)) notice = null }
}
