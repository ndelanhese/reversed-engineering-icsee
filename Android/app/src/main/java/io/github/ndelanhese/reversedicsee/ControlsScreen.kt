package io.github.ndelanhese.reversedicsee

import android.app.AlertDialog
import android.view.View
import android.widget.*
import org.json.JSONArray
import org.json.JSONObject

class ControlsScreen(app: MainActivity, private val camera: CameraProfile, private val credentials: Credentials) : CameraScreen(app) {
    private var profiles = JSONArray()
    private var profile = JSONObject()
    private var controls: LinearLayout? = null
    private var moving = false
    private var preview: VideoPane? = null
    override fun show() {
        scope.close(); scope = WorkScope()
        preview?.close(); preview = null
        val root = app.frame(camera.name)
        val tabs = app.row(root)
        app.button(tabs, R.string.controls) { show() }
        app.button(tabs, R.string.settings) { settings() }
        app.button(tabs, R.string.credentials) { app.authenticate(camera, true) { app.navigate(ControlsScreen(app, camera, it)) } }
        val body = app.scroll(root); controls = body
        val pane = app.video().also { body.addView(it, LinearLayout.LayoutParams(-1, app.dp(220))); preview = it }
        val scroll = body.parent as ScrollView
        fun visibility() {
            if (preview !== pane) return
            val bounds = android.graphics.Rect()
            val visible = pane.getGlobalVisibleRect(bounds) && bounds.height() > app.dp(32)
            if (visible && !pane.intentToPlay) pane.live(camera, credentials)
            if (!visible && pane.intentToPlay) pane.suspendLive()
        }
        scroll.setOnScrollChangeListener { _, _, _, _, _ -> visibility() }
        body.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> visibility() }
        body.post { visibility() }
        val status = app.text(body, app.getString(R.string.loading))
        scope.run(camera.request("onvif_discover", credentials), { result ->
            profiles = (result as JSONObject).getJSONArray("profiles")
            body.removeView(status)
            if (profiles.length() == 0) { app.text(body, app.getString(R.string.unavailable)); return@run }
            val selector = Spinner(app)
            val names = (0 until profiles.length()).map { profiles.getJSONObject(it).optString("name").ifBlank { profiles.getJSONObject(it).getString("token") } }
            selector.adapter = ArrayAdapter(app, android.R.layout.simple_spinner_dropdown_item, names)
            body.addView(selector)
            val panel = app.column(); body.addView(panel)
            selector.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
                override fun onNothingSelected(parent: android.widget.AdapterView<*>?) = Unit
                override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                    scope.close(); scope = WorkScope(); moving = false
                    profile = profiles.getJSONObject(position); renderProfile(panel)
                }
            }
        }, { code -> status.text = errorMessage(app, code) })
    }
    private fun request(op: String): JSONObject = camera.request(op, credentials).put("profile", profile.getString("token"))
    private fun renderProfile(panel: LinearLayout) {
        panel.removeAllViews()
        val speedLabel = app.text(panel, app.getString(R.string.speed))
        val speed = SeekBar(app).apply { max = 100; progress = 35; panel.addView(this) }
        val pad = app.column(); panel.addView(pad)
        fun move(pan: Double, tilt: Double, zoom: Double) {
            if (moving) return
            moving = true
            val factor = speed.progress.coerceAtLeast(1) / 100.0
            fun velocity(axis: String, direction: Double): Double {
                if (direction == 0.0) return 0.0
                val range = profile.optJSONArray(axis) ?: return 0.0
                return (if (direction < 0) range.getDouble(0).coerceAtMost(0.0) else range.getDouble(1).coerceAtLeast(0.0)) * factor
            }
            scope.run(request("onvif_move").put("pan", velocity("pan", pan)).put("tilt", velocity("tilt", tilt)).put("zoom", velocity("zoom", zoom)), { moving = false }, { moving = false; error(it) })
        }
        val up = app.row(pad); app.button(up, "↑") { move(0.0, 1.0, 0.0) }.apply { contentDescription = app.getString(R.string.tilt_up); isEnabled = profile.optJSONArray("tilt") != null }
        val middle = app.row(pad)
        app.button(middle, "←") { move(-1.0, 0.0, 0.0) }.apply { contentDescription = app.getString(R.string.pan_left); isEnabled = profile.optJSONArray("pan") != null }
        app.button(middle, R.string.stop) {
            scope.close(); scope = WorkScope(); moving = false
            scope.run(request("onvif_stop"), {}, ::error)
        }
        app.button(middle, "→") { move(1.0, 0.0, 0.0) }.apply { contentDescription = app.getString(R.string.pan_right); isEnabled = profile.optJSONArray("pan") != null }
        val down = app.row(pad); app.button(down, "↓") { move(0.0, -1.0, 0.0) }.apply { contentDescription = app.getString(R.string.tilt_down); isEnabled = profile.optJSONArray("tilt") != null }
        if (profile.optJSONArray("zoom") != null) { val row = app.row(pad); app.button(row, "−") { move(0.0, 0.0, -1.0) }; app.button(row, "+") { move(0.0, 0.0, 1.0) } }
        app.button(panel, R.string.presets) { presets(panel) }
        app.button(panel, R.string.save_preset) {
            val form = app.column(); val name = app.edit(form, R.string.preset_name, "")
            AlertDialog.Builder(app).setTitle(R.string.save_preset).setView(form).setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.save) { _, _ ->
                scope.run(request("onvif_save_preset").put("name", name.text.toString()), { app.message(app.getString(R.string.verified)) }, ::error)
            }.show()
        }
        app.button(panel, R.string.image) { imaging(panel) }
    }
    private fun presets(panel: LinearLayout) {
        scope.run(request("onvif_presets"), { result ->
            val presets = (result as JSONObject).getJSONArray("presets")
            if (presets.length() == 0) { app.message(app.getString(R.string.unavailable)); return@run }
            AlertDialog.Builder(app).setTitle(R.string.presets).setItems((0 until presets.length()).map { presets.getJSONObject(it).optString("name") }.toTypedArray()) { _, index ->
                scope.run(request("onvif_goto_preset").put("preset", presets.getJSONObject(index).getString("token")), {}, ::error)
            }.setNegativeButton(R.string.cancel, null).show()
        }, ::error)
    }
    private fun imaging(panel: LinearLayout) {
        scope.run(request("onvif_imaging"), { result ->
            val fields = (result as JSONObject).getJSONArray("fields")
            val form = app.column(); val edits = mutableListOf<Pair<JSONObject, EditText>>()
            for (i in 0 until fields.length()) {
                val f = fields.getJSONObject(i)
                val edit = app.edit(form, f.getString("path"), f.getString("value"))
                edit.isEnabled = f.optBoolean("writable")
                val range = f.optJSONArray("range"); val choices = f.optJSONArray("choices")
                if (range != null) app.text(form, "${range.getDouble(0)} … ${range.getDouble(1)}", 12f)
                if (choices != null && choices.length() > 0) app.text(form, choices.join(", "), 12f)
                edits.add(f to edit)
            }
            val scroll = ScrollView(app).apply { addView(form) }
            val dialog = AlertDialog.Builder(app).setTitle(R.string.image).setView(scroll).setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.apply, null).create()
            dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val changes = JSONArray()
                for ((original, edit) in edits) if (edit.isEnabled && edit.text.toString() != original.getString("value")) changes.put(JSONObject().put("path", original.getString("path")).put("original", original.getString("value")).put("value", edit.text.toString()))
                app.confirm(app.getString(R.string.apply), app.getString(R.string.apply_confirm)) {
                    scope.run(request("onvif_set_imaging").put("changes", changes), { dialog.dismiss(); app.message(app.getString(R.string.verified)) }, ::error)
                }
            } }; dialog.show()
        }, ::error)
    }
    private fun groupLabel(group: String): String = app.getString(when (group) {
        "Device information" -> R.string.group_device
        "Image and lighting" -> R.string.group_image
        "Video and audio" -> R.string.group_video
        "Detection and alarms" -> R.string.group_detection
        "Recording and storage" -> R.string.group_storage
        "Network" -> R.string.group_network
        "Time and privacy" -> R.string.group_privacy
        "Movement settings" -> R.string.group_movement
        else -> R.string.settings
    })
    private fun settings() {
        preview?.close(); preview = null
        scope.close(); scope = WorkScope()
        val root = app.frame(camera.name)
        app.button(root, R.string.controls) { show() }
        val body = app.scroll(root)
        val status = app.text(body, app.getString(R.string.settings))
        var scanning = false
        var cursor = 0
        var catalog = JSONArray()
        val available = app.column(); body.addView(available)
        fun scanNext() {
            if (!scanning || cursor >= catalog.length()) { scanning = false; status.text = app.getString(R.string.settings); return }
            val section = catalog.getJSONObject(cursor++)
            status.text = "${app.getString(R.string.loading)} $cursor/${catalog.length()}"
            scope.run(camera.request("settings_read", credentials).put("name", section.getString("name")), { result ->
                app.button(available, "${groupLabel(section.getString("group"))} · ${section.getString("name")}") { editSection(section, (result as JSONObject).get("value")) }
                scanNext()
            }, { code -> if (code == "authentication" || code == "unreachable") { scanning = false; error(code) } else scanNext() })
        }
        app.button(body, R.string.scan) { if (!scanning) { scanning = true; scanNext() } }
        app.button(body, R.string.stop_scan) { scanning = false; scope.close(); scope = WorkScope(); status.text = app.getString(R.string.settings) }
        app.button(body, R.string.restart) { app.confirm(app.getString(R.string.restart), app.getString(R.string.restart_confirm)) {
            scope.run(camera.request("reboot", credentials).put("confirmed", true), { app.connected.remove(camera.id); app.message(app.getString(R.string.error_disconnected)) }, ::error)
        } }
        scope.run(JSONObject().put("op", "settings_catalog"), { catalog = it as JSONArray }, ::error)
    }
    private fun editSection(section: JSONObject, original: Any) {
        val name = section.getString("name")
        // Reload when opening; the discovery snapshot may already be stale.
        scope.run(camera.request("settings_read", credentials).put("name", name), { result ->
            val fresh = (result as JSONObject).get("value")
            SettingsDialog(app, scope, camera, credentials, section, fresh, ::error).show()
        }, ::error)
    }
    override fun pause() { super.pause(); preview?.close(); preview = null }
}

class SettingsDialog(private val app: MainActivity, private val scope: WorkScope, private val camera: CameraProfile, private val credentials: Credentials, private val section: JSONObject, private val original: Any, private val error: (String) -> Unit) {
    fun show() {
        val updated: Any = when (original) { is JSONObject -> JSONObject(original.toString()); is JSONArray -> JSONArray(original.toString()); else -> original }
        val form = app.column()
        val applyEdits = mutableListOf<() -> Unit>()
        fun walk(value: Any, target: Any, path: String, sensitive: Boolean = false) {
            when (value) {
                is JSONObject -> for (key in value.keys().asSequence().toList()) {
                    val secret = sensitive || Regex("password|passwd|pwd|secret|token|privatekey", RegexOption.IGNORE_CASE).containsMatchIn(key)
                    val v = value.get(key); val t = (target as JSONObject).get(key)
                    if (v is JSONObject || v is JSONArray) walk(v, t, "$path/$key", secret)
                    else scalar(v, "$path/$key", secret) { target.put(key, it) }
                }
                is JSONArray -> for (index in 0 until value.length()) {
                    val v = value.get(index); val t = (target as JSONArray).get(index)
                    if (v is JSONObject || v is JSONArray) walk(v, t, "$path/$index", sensitive)
                    else scalar(v, "$path/$index", sensitive) { target.put(index, it) }
                }
            }
        }
        // Scalar editor retains firmware field names, value types and array positions.
        scalarBuilder = { value, path, secret, set ->
            if (secret) app.text(form, "$path: ••••••", 13f)
            else {
                val edit = app.edit(form, path, value.toString())
                edit.isEnabled = !section.optBoolean("readOnly") && value !== JSONObject.NULL
                if (edit.isEnabled) applyEdits.add {
                    val text = edit.text.toString()
                    val parsed: Any = when (value) {
                        is Boolean -> when (text.lowercase()) { "true" -> true; "false" -> false; else -> throw CameraFailure("invalid_input") }
                        is Number -> java.math.BigDecimal(text)
                        else -> text
                    }
                    set(parsed)
                }
            }
        }
        walk(original, updated, "")
        val scroll = ScrollView(app).apply { addView(form) }
        val dialog = AlertDialog.Builder(app).setTitle(section.getString("name")).setView(scroll).setNegativeButton(R.string.cancel, null)
            .setPositiveButton(if (section.optBoolean("readOnly")) R.string.back else R.string.apply, null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            if (section.optBoolean("readOnly")) { dialog.dismiss(); return@setOnClickListener }
            if (runCatching { applyEdits.forEach { it() } }.isFailure) { error("invalid_input"); return@setOnClickListener }
            app.confirm(app.getString(R.string.apply), app.getString(R.string.apply_confirm)) {
                scope.run(camera.request("settings_write", credentials).put("name", section.getString("name")).put("original", original).put("updated", updated), { result ->
                    dialog.dismiss(); val r = result as JSONObject
                    app.message(app.getString(if (r.optBoolean("requiresRestart")) R.string.restart_pending else R.string.verified))
                }, error)
            }
        } }; dialog.show()
    }
    private var scalarBuilder: ((Any, String, Boolean, (Any) -> Unit) -> Unit)? = null
    private fun scalar(value: Any, path: String, secret: Boolean, set: (Any) -> Unit) = scalarBuilder!!.invoke(value, path, secret, set)
}
