package io.github.ndelanhese.reversedicsee

import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ProgressBar
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
        val results = app.scroll(root)
        app.text(results, app.getString(R.string.discovery_intro), 15f).setPadding(app.dp(8), 0, app.dp(8), app.dp(16))
        val status = app.column().apply { background = app.surface(); setPadding(app.dp(16), app.dp(14), app.dp(16), app.dp(14)) }
        results.addView(status, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = app.dp(12) })
        val message = app.row(status)
        if (searching) {
            val progress = ProgressBar(app).apply { indeterminateTintList = android.content.res.ColorStateList.valueOf(app.accent) }
            message.addView(progress, LinearLayout.LayoutParams(app.dp(24), app.dp(24)).apply { marginEnd = app.dp(12) })
        }
        app.text(message, notice ?: app.getString(R.string.discovery_ready), 15f).layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
        val actions = app.row(status)
        app.button(actions, R.string.search_again) { search() }.apply { isEnabled = !searching; if (!searching) app.primary(this) }
        app.button(actions, R.string.stop_scan) { stop(); notice = null; show() }.isEnabled = searching
        app.button(results, R.string.add_manually) { app.editCamera() }
        if (cameras.isNotEmpty()) {
            app.text(results, app.getString(R.string.discovery_results), 18f).apply {
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL); setPadding(app.dp(8), app.dp(20), 0, app.dp(4))
            }
            app.text(results, app.getString(R.string.discovery_add_hint), 13f).setPadding(app.dp(8), 0, app.dp(8), app.dp(12))
        }
        for (camera in cameras) {
            val saved = app.profiles.any { it.host.equals(camera.host, ignoreCase = true) }
            val label = "${camera.name}\n${camera.host}:${camera.onvifPort}" + if (saved) "\n${app.getString(R.string.already_added)}" else ""
            app.button(results, label) { app.editCamera(discovered = camera) }.apply {
                isEnabled = !saved; gravity = Gravity.START or Gravity.CENTER_VERTICAL
                setPadding(app.dp(18), app.dp(16), app.dp(18), app.dp(16))
                setTextColor(if (saved) app.muted else app.ink)
                background = android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(app.getColor(R.color.ui_ripple)), app.surface(), null)
                setCompoundDrawablesRelativeWithIntrinsicBounds(R.drawable.ic_camera, 0, if (saved) 0 else R.drawable.ic_add, 0)
                compoundDrawablePadding = app.dp(14)
                compoundDrawableTintList = android.content.res.ColorStateList.valueOf(if (saved) app.muted else app.ink)
            }
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
