package io.github.ndelanhese.reversedicsee

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.*
import org.json.JSONObject
import org.videolan.libvlc.LibVLC

abstract class CameraScreen(val app: MainActivity) : AutoCloseable {
    var scope = WorkScope()
    abstract fun show()
    open fun pause() { scope.close() }
    open fun resume() { scope = WorkScope(); show() }
    override fun close() = pause()
    fun error(code: String) { if (code != "cancelled") app.message(errorMessage(app, code)) }
}

class MainActivity : Activity() {
    val storage by lazy { CameraStorage(this) }
    val vault by lazy { CredentialVault(this) }
    val vlc by lazy { LibVLC(this, arrayListOf("--quiet", "--no-video-title-show", "--no-metadata-network-access", "--no-lua")) }
    val credentials = mutableMapOf<String, Credentials>()
    val connected = mutableSetOf<String>()
    var profiles = emptyList<CameraProfile>()
    private var screen: CameraScreen? = null
    var pickingExport = false
    var exportResult: ((android.net.Uri?) -> Unit)? = null
    private var pendingNetworkAction: (() -> Unit)? = null
    private var started = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PlaybackCache.prune(this)
        profiles = storage.load()
        navigate(DashboardScreen(this))
    }
    override fun onResume() { super.onResume(); if (started) screen?.resume(); started = true }
    override fun onPause() { screen?.pause(); super.onPause() }
    override fun onDestroy() { screen?.close(); credentials.clear(); if (vlcInitialized) vlc.release(); super.onDestroy() }
    private var vlcInitialized = false
    fun video(): VideoPane { vlcInitialized = true; return VideoPane(this, vlc) }
    override fun onConfigurationChanged(newConfig: Configuration) { super.onConfigurationChanged(newConfig); window.decorView.requestLayout() }
    @Deprecated("Native back compatibility") override fun onBackPressed() { navigate(DashboardScreen(this)) }
    fun navigate(next: CameraScreen) { screen?.close(); screen = next; next.show() }
    fun persist() { storage.save(profiles) }
    fun message(value: String) { Toast.makeText(this, value, Toast.LENGTH_LONG).show() }
    fun confirm(title: String, body: String, action: () -> Unit) {
        AlertDialog.Builder(this).setTitle(title).setMessage(body).setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.apply) { _, _ -> action() }.show()
    }
    fun network(action: () -> Unit) {
        if (Build.VERSION.SDK_INT >= 37 && checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") != PackageManager.PERMISSION_GRANTED) {
            pendingNetworkAction = action
            requestPermissions(arrayOf("android.permission.ACCESS_LOCAL_NETWORK"), 100)
        } else action()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 100) { val action = pendingNetworkAction; pendingNetworkAction = null; if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) action?.invoke() else message(getString(R.string.permission_denied)) }
    }
    fun authenticate(camera: CameraProfile, force: Boolean = false, action: (Credentials) -> Unit) = network {
        if (!force) {
            credentials[camera.id]?.let { action(it); return@network }
            runCatching { vault.load(camera.id) }.fold({ value -> if (value != null) { credentials[camera.id] = value; action(value); return@network } }, { message(getString(R.string.saved_unavailable)) })
        }
        val form = column()
        val user = edit(form, R.string.username, credentials[camera.id]?.username ?: "admin")
        val password = edit(form, R.string.password, "", secret = true)
        val remember = CheckBox(this).apply { setText(R.string.remember); form.addView(this) }
        val dialog = AlertDialog.Builder(this).setTitle(camera.name).setView(form).setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.authentication, null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            if (user.text.isBlank()) { user.error = getString(R.string.error_invalid_input); return@setOnClickListener }
            val c = Credentials(user.text.toString(), password.text.toString())
            val result = runCatching { if (remember.isChecked) vault.save(camera.id, c) else vault.remove(camera.id) }
            if (result.isFailure) { message(getString(R.string.error_file_io)); return@setOnClickListener }
            credentials[camera.id] = c; password.text.clear(); dialog.dismiss(); action(c)
        } }
        dialog.show()
    }
    fun editCamera(old: CameraProfile? = null) {
        val form = column(); val name = edit(form, R.string.camera_name, old?.name ?: "")
        val host = edit(form, R.string.address, old?.host ?: "")
        val port = edit(form, R.string.rtsp_port, (old?.port ?: 554).toString(), number = true)
        val control = edit(form, R.string.control_port, (old?.controlPort ?: 34567).toString(), number = true)
        val onvif = edit(form, R.string.onvif_port, (old?.onvifPort ?: 8899).toString(), number = true)
        val channel = edit(form, R.string.channel, (old?.channel ?: 1).toString(), number = true)
        val sub = CheckBox(this).apply { setText(R.string.substream); isChecked = old?.substream ?: true; form.addView(this) }
        val scroll = ScrollView(this).apply { addView(form) }
        val dialog = AlertDialog.Builder(this).setTitle(if (old == null) R.string.add_camera else R.string.edit).setView(scroll).setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.save, null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val p = CameraProfile(id = old?.id ?: java.util.UUID.randomUUID().toString(), name = name.text.toString().trim(), host = host.text.toString().trim(), port = port.text.toString().toIntOrNull() ?: 0, controlPort = control.text.toString().toIntOrNull() ?: 0, onvifPort = onvif.text.toString().toIntOrNull() ?: 0, channel = channel.text.toString().toIntOrNull() ?: 0, substream = sub.isChecked)
            if (!p.valid() || old == null && profiles.size >= 64) { host.error = getString(R.string.error_invalid_input); return@setOnClickListener }
            profiles = if (old == null) profiles + p else profiles.map { if (it.id == old.id) p else it }
            connected.remove(p.id)
            runCatching { persist() }.onFailure { message(getString(R.string.error_file_io)); return@setOnClickListener }
            dialog.dismiss(); navigate(DashboardScreen(this))
        } }
        dialog.show()
    }
    fun document(name: String, mime: String, callback: (android.net.Uri?) -> Unit) {
        pickingExport = true; exportResult = callback
        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(mime).putExtra(Intent.EXTRA_TITLE, name), 200)
    }
    @Deprecated("Document picker compatibility") override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 200) { val callback = exportResult; exportResult = null; pickingExport = false; callback?.invoke(if (resultCode == RESULT_OK) data?.data else null) }
    }
    fun column(): LinearLayout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(10), dp(16), dp(10)) }
    fun row(parent: LinearLayout): LinearLayout = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; parent.addView(this, LinearLayout.LayoutParams(-1, -2)) }
    fun text(parent: LinearLayout, value: String, size: Float = 16f): TextView = TextView(this).apply { text = value; textSize = size; setTextColor(0xffe3e8ef.toInt()); setPadding(0, dp(6), 0, dp(6)); parent.addView(this) }
    fun button(parent: LinearLayout, id: Int, action: () -> Unit): Button = button(parent, getString(id), action)
    fun button(parent: LinearLayout, value: String, action: () -> Unit): Button = Button(this).apply {
        text = value; isAllCaps = false; setOnClickListener { action() }
        parent.addView(this, if (parent.orientation == LinearLayout.HORIZONTAL) LinearLayout.LayoutParams(0, -2, 1f) else LinearLayout.LayoutParams(-1, -2))
    }
    fun edit(parent: LinearLayout, label: Int, value: String, number: Boolean = false, secret: Boolean = false): EditText = edit(parent, getString(label), value, number, secret)
    fun edit(parent: LinearLayout, label: String, value: String, number: Boolean = false, secret: Boolean = false): EditText {
        text(parent, label, 13f)
        return EditText(this).apply { setText(value); isSingleLine = true; isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO; inputType = when { secret -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD; number -> InputType.TYPE_CLASS_NUMBER; else -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS }; if (secret) imeOptions = android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING; parent.addView(this) }
    }
    fun frame(title: String, back: Boolean = true): LinearLayout {
        val root = column()
        root.setOnApplyWindowInsetsListener { view, insets ->
            val top: Int; val bottom: Int
            if (Build.VERSION.SDK_INT >= 30) { val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()); top = bars.top; bottom = bars.bottom }
            else { top = insets.systemWindowInsetTop; bottom = insets.systemWindowInsetBottom }
            view.setPadding(dp(12), top + dp(6), dp(12), bottom + dp(6)); insets
        }
        val header = row(root)
        if (back) button(header, R.string.back) { navigate(DashboardScreen(this)) }.layoutParams = LinearLayout.LayoutParams(-2, -2)
        text(header, title, 22f).layoutParams = LinearLayout.LayoutParams(0, -2, 1f)
        setContentView(root); return root
    }
    fun scroll(root: LinearLayout): LinearLayout { val content = column(); root.addView(ScrollView(this).apply { isFillViewport = true; addView(content) }, LinearLayout.LayoutParams(-1, 0, 1f)); return content }
    fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}

class DashboardScreen(app: MainActivity) : CameraScreen(app) {
    private val videos = mutableListOf<VideoPane>()
    override fun show() {
        videos.forEach { it.close() }; videos.clear()
        val root = app.frame(app.getString(R.string.cameras), false)
        app.text(root, app.getString(R.string.intro))
        app.button(root, R.string.add_camera) { app.editCamera() }
        app.button(root, R.string.about) {
            val content = app.column()
            val notice = app.assets.open("THIRD_PARTY_NOTICES.txt").bufferedReader().use { it.readText() }
            app.text(content, notice, 13f).autoLinkMask = android.text.util.Linkify.WEB_URLS
            android.app.AlertDialog.Builder(app).setTitle(R.string.about).setView(ScrollView(app).apply { addView(content) }).setPositiveButton(R.string.back, null).show()
        }
        val content = app.scroll(root)
        if (app.profiles.isEmpty()) app.text(content, app.getString(R.string.empty))
        val cards = mutableListOf<Triple<CameraProfile, LinearLayout, VideoPane?>>()
        for (camera in app.profiles) {
            val card = app.column().apply { setBackgroundColor(0xff1c222b.toInt()) }
            content.addView(card, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = app.dp(16) })
            app.text(card, camera.name, 20f)
            app.text(card, camera.host, 13f)
            val video = if (camera.id in app.connected && app.credentials[camera.id] != null) app.video().also { card.addView(it, LinearLayout.LayoutParams(-1, app.dp(220))); videos.add(it) } else null
            cards.add(Triple(camera, card, video))
            val actions = app.row(card)
            app.button(actions, if (camera.id in app.connected) R.string.stop else R.string.connect) {
                if (camera.id in app.connected) { app.connected.remove(camera.id); show() }
                else app.authenticate(camera) { app.connected.add(camera.id); show() }
            }
            app.button(actions, R.string.fullscreen) { app.authenticate(camera) { credentials -> app.connected.add(camera.id); app.navigate(EnlargedScreen(app, camera, credentials)) } }
            app.button(actions, "⋯") { menu(camera, actions) }.contentDescription = app.getString(R.string.more)
        }
        val scroll = content.parent as ScrollView
        fun visibility() { val bounds = Rect(); for ((camera, card, video) in cards) {
            if (video == null) continue
            val visible = video.getGlobalVisibleRect(bounds) && bounds.height() > app.dp(32)
            if (visible && !video.intentToPlay) app.credentials[camera.id]?.let { video.live(camera, it) }
            if (!visible && video.intentToPlay) video.suspendLive()
        } }
        scroll.setOnScrollChangeListener { _, _, _, _, _ -> visibility() }; content.post { visibility() }
    }
    private fun menu(camera: CameraProfile, anchor: View) {
        val menu = PopupMenu(app, anchor)
        for (id in listOf(R.string.controls, R.string.recordings, R.string.credentials, R.string.edit, R.string.delete)) menu.menu.add(0, id, 0, id)
        menu.setOnMenuItemClickListener { item -> when (item.itemId) {
            R.string.controls -> app.authenticate(camera) { app.navigate(ControlsScreen(app, camera, it)) }
            R.string.recordings -> app.authenticate(camera) { app.navigate(RecordingsScreen(app, camera, it)) }
            R.string.credentials -> app.authenticate(camera, true) { app.connected.remove(camera.id); show() }
            R.string.edit -> app.editCamera(camera)
            R.string.delete -> app.confirm(app.getString(R.string.delete), app.getString(R.string.delete_confirm)) { app.profiles = app.profiles.filter { it.id != camera.id }; app.connected.remove(camera.id); app.credentials.remove(camera.id); app.vault.remove(camera.id); app.persist(); show() }
        }; true }; menu.show()
    }
    override fun pause() { super.pause(); videos.forEach { it.close() }; videos.clear() }
}

class EnlargedScreen(app: MainActivity, private val camera: CameraProfile, private val credentials: Credentials) : CameraScreen(app) {
    private var video: VideoPane? = null
    override fun show() {
        video?.close()
        val root = app.frame(camera.name)
        val pane = app.video(); video = pane
        root.addView(pane, LinearLayout.LayoutParams(-1, 0, 1f)); pane.live(camera, credentials)
        val actions = app.row(root)
        app.button(actions, R.string.controls) { app.navigate(ControlsScreen(app, camera, credentials)) }
        app.button(actions, R.string.recordings) { app.navigate(RecordingsScreen(app, camera, credentials)) }
    }
    override fun pause() { super.pause(); video?.close(); video = null }
}
