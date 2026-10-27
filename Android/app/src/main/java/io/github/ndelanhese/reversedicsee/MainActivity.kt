package io.github.ndelanhese.reversedicsee

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.text.TextUtils
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
    val vlc by lazy { LibVLC(this, arrayListOf("--quiet", "--verbose=-1", "--no-video-title-show", "--no-metadata-network-access", "--no-lua")) }
    val credentials = mutableMapOf<String, Credentials>()
    val connected = mutableSetOf<String>()
    var profiles = emptyList<CameraProfile>()
    private var screen: CameraScreen? = null
    var pickingExport = false
    var exportResult: ((android.net.Uri?) -> Unit)? = null
    private var pendingNetworkAction: (() -> Unit)? = null
    private var grantedNetworkAction: (() -> Unit)? = null
    private var resumed = false
    private var started = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PlaybackCache.prune(this)
        profiles = storage.load()
        navigate(DashboardScreen(this))
    }
    override fun onResume() {
        super.onResume(); if (started) screen?.resume(); started = true; resumed = true
        val action = grantedNetworkAction; grantedNetworkAction = null; action?.invoke()
    }
    override fun onPause() { resumed = false; screen?.pause(); super.onPause() }
    override fun onDestroy() { pendingNetworkAction = null; grantedNetworkAction = null; screen?.close(); credentials.clear(); if (vlcInitialized) vlc.release(); super.onDestroy() }
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
            val requestingScreen = screen
            pendingNetworkAction = { if (screen === requestingScreen) action() }
            requestPermissions(arrayOf("android.permission.ACCESS_LOCAL_NETWORK"), 100)
        } else action()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 100) {
            val action = pendingNetworkAction; pendingNetworkAction = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                // Android can deliver permission results before resuming the screen and its scope.
                if (resumed) action?.invoke() else grantedNetworkAction = action
            } else { grantedNetworkAction = null; message(getString(R.string.permission_denied)) }
        }
    }
    fun authenticate(camera: CameraProfile, force: Boolean = false, action: (Credentials) -> Unit) = network {
        if (!force) {
            credentials[camera.id]?.let { action(it); return@network }
            runCatching { vault.load(camera.id) }.fold({ value -> if (value != null) { credentials[camera.id] = value; action(value); return@network } }, { message(getString(R.string.saved_unavailable)) })
        }
        val form = column()
        text(form, getString(R.string.authentication_hint), 14f)
        val user = edit(form, R.string.username, credentials[camera.id]?.username ?: "admin")
        val password = edit(form, R.string.password, "", secret = true)
        val remember = check(form, R.string.remember)
        val dialog = AlertDialog.Builder(this).setTitle(camera.name).setView(ScrollView(this).apply { addView(form) }).setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.authentication, null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            if (user.text.isBlank()) { user.error = getString(R.string.error_invalid_input); return@setOnClickListener }
            val c = Credentials(user.text.toString(), password.text.toString())
            val result = runCatching { if (remember.isChecked) vault.save(camera.id, c) else vault.remove(camera.id) }
            if (result.isFailure) { message(getString(R.string.error_file_io)); return@setOnClickListener }
            credentials[camera.id] = c; password.text.clear(); dialog.dismiss(); action(c)
        } }
        dialog.show()
    }
    fun editCamera(old: CameraProfile? = null, discovered: CameraProfile? = null) {
        val initial = old ?: discovered
        val form = column(); text(form, getString(R.string.camera_details), 14f)
        val name = edit(form, R.string.camera_name, initial?.name ?: "")
        val host = edit(form, R.string.address, initial?.host ?: "")
        val advanced = column().apply { visibility = View.GONE }
        check(form, R.string.advanced).apply { setOnCheckedChangeListener { _, checked -> advanced.visibility = if (checked) View.VISIBLE else View.GONE } }
        form.addView(advanced)
        val port = edit(advanced, R.string.rtsp_port, (initial?.port ?: 554).toString(), number = true)
        val control = edit(advanced, R.string.control_port, (initial?.controlPort ?: 34567).toString(), number = true)
        val onvif = edit(advanced, R.string.onvif_port, (initial?.onvifPort ?: 8899).toString(), number = true)
        val channel = edit(advanced, R.string.channel, (initial?.channel ?: 1).toString(), number = true)
        val sub = check(advanced, R.string.substream).apply { isChecked = initial?.substream ?: true }
        if (discovered != null) text(form, getString(R.string.discovery_defaults), 13f)
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
    val ink get() = getColor(R.color.ui_text)
    val muted get() = getColor(R.color.ui_muted)
    val accent get() = getColor(R.color.ui_accent)
    fun surface(color: Int = getColor(R.color.ui_surface), radius: Int = 16, stroke: Int? = null): GradientDrawable = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat(); if (stroke != null) setStroke(dp(1), stroke)
    }
    fun column(): LinearLayout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(12), dp(20), dp(16)) }
    fun row(parent: LinearLayout): LinearLayout = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; parent.addView(this, LinearLayout.LayoutParams(-1, -2)) }
    fun text(parent: LinearLayout, value: String, size: Float = 16f): TextView = TextView(this).apply {
        text = value; textSize = size; setTextColor(if (size < 16f) muted else ink); setLineSpacing(dp(2).toFloat(), 1f)
        setPadding(0, dp(6), 0, dp(6)); parent.addView(this, LinearLayout.LayoutParams(-1, -2))
    }
    fun button(parent: LinearLayout, id: Int, action: () -> Unit): Button = button(parent, getString(id), action)
    fun button(parent: LinearLayout, value: String, action: () -> Unit): Button = Button(this).apply {
        text = value; isAllCaps = false; textSize = 14f; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        minHeight = dp(48); minimumHeight = dp(48); minWidth = 0; minimumWidth = 0; gravity = Gravity.CENTER
        setPadding(dp(12), dp(8), dp(12), dp(8)); setTextColor(ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()), intArrayOf(getColor(R.color.ui_disabled), accent)))
        background = RippleDrawable(ColorStateList.valueOf(getColor(R.color.ui_ripple)), surface(getColor(R.color.ui_button), 12), null)
        stateListAnimator = null; setOnClickListener { action() }
        parent.addView(this, (if (parent.orientation == LinearLayout.HORIZONTAL) LinearLayout.LayoutParams(0, -2, 1f) else LinearLayout.LayoutParams(-1, -2)).apply {
            topMargin = dp(4); bottomMargin = dp(4); if (parent.orientation == LinearLayout.HORIZONTAL) { marginStart = dp(3); marginEnd = dp(3) }
        })
    }
    fun primary(button: Button) {
        button.setTextColor(ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()), intArrayOf(getColor(R.color.ui_primary_disabled), getColor(R.color.ui_on_accent))))
        button.background = RippleDrawable(ColorStateList.valueOf(getColor(R.color.ui_primary_ripple)), surface(accent, 12), null)
    }
    fun icon(parent: LinearLayout, drawable: Int, label: Int, action: () -> Unit): ImageButton = ImageButton(this).apply {
        setImageResource(drawable); imageTintList = ColorStateList.valueOf(ink); contentDescription = getString(label)
        background = RippleDrawable(ColorStateList.valueOf(getColor(R.color.ui_ripple)), surface(0x00000000, 24), null)
        setPadding(dp(12), dp(12), dp(12), dp(12)); setOnClickListener { action() }
        parent.addView(this, LinearLayout.LayoutParams(dp(48), dp(48)))
    }
    fun check(parent: LinearLayout, label: Int): CheckBox = CheckBox(this).apply {
        setText(label); textSize = 14f; setTextColor(ink); minHeight = dp(48); buttonTintList = ColorStateList.valueOf(accent)
        parent.addView(this, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
    }
    fun edit(parent: LinearLayout, label: Int, value: String, number: Boolean = false, secret: Boolean = false): EditText = edit(parent, getString(label), value, number, secret)
    fun edit(parent: LinearLayout, label: String, value: String, number: Boolean = false, secret: Boolean = false): EditText {
        val caption = text(parent, label, 13f).apply { setPadding(0, dp(14), 0, dp(6)) }
        return EditText(this).apply {
            id = View.generateViewId(); caption.labelFor = id
            setText(value); contentDescription = label; textSize = 16f; setTextColor(ink); setHintTextColor(muted)
            background = surface(getColor(R.color.ui_field), 10, getColor(R.color.ui_outline)); setPadding(dp(14), dp(12), dp(14), dp(12)); minHeight = dp(48)
            isSingleLine = true; isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            inputType = when { secret -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD; number -> InputType.TYPE_CLASS_NUMBER; else -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS }
            if (secret) imeOptions = android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
            parent.addView(this, LinearLayout.LayoutParams(-1, -2))
        }
    }
    fun frame(title: String, back: Boolean = true): LinearLayout {
        val root = column().apply { setBackgroundColor(getColor(R.color.ui_canvas)) }
        root.setOnApplyWindowInsetsListener { view, insets ->
            val top: Int; val bottom: Int
            if (Build.VERSION.SDK_INT >= 30) { val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()); top = bars.top; bottom = bars.bottom }
            else { top = insets.systemWindowInsetTop; bottom = insets.systemWindowInsetBottom }
            view.setPadding(dp(12), top + dp(6), dp(12), bottom + dp(6)); insets
        }
        val header = row(root)
        if (back) icon(header, R.drawable.ic_back, R.string.back) { navigate(DashboardScreen(this)) }
        text(header, title, 22f).apply {
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL); maxLines = 1; ellipsize = TextUtils.TruncateAt.END
            layoutParams = LinearLayout.LayoutParams(0, dp(56), 1f); gravity = Gravity.CENTER_VERTICAL
            setPadding(if (back) 0 else dp(8), 0, 0, 0)
        }
        setContentView(root); return root
    }
    fun scroll(root: LinearLayout): LinearLayout {
        val content = column().apply { setPadding(dp(4), dp(8), dp(4), dp(16)) }
        root.addView(ScrollView(this).apply { isFillViewport = true; clipToPadding = false; addView(content) }, LinearLayout.LayoutParams(-1, 0, 1f)); return content
    }

    fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}

class DashboardScreen(app: MainActivity) : CameraScreen(app) {
    private val videos = mutableListOf<VideoPane>()
    override fun show() {
        videos.forEach { it.close() }; videos.clear()
        val root = app.frame(app.getString(R.string.cameras), false)
        val header = root.getChildAt(0) as LinearLayout
        app.icon(header, R.drawable.ic_discover, R.string.find_cameras) { app.navigate(DiscoveryScreen(app)) }
        app.icon(header, R.drawable.ic_add, R.string.add_camera) { app.editCamera() }
        app.icon(header, R.drawable.ic_more, R.string.more) { aboutMenu(header) }
        app.text(root, app.getString(R.string.intro), 14f).setPadding(app.dp(8), 0, 0, app.dp(12))
        val content = app.scroll(root)
        if (app.profiles.isEmpty()) {
            val empty = app.column().apply { background = app.surface(); setPadding(app.dp(24), app.dp(28), app.dp(24), app.dp(24)) }
            content.addView(empty)
            ImageView(app).apply { setImageResource(R.drawable.ic_camera); imageTintList = ColorStateList.valueOf(app.accent); empty.addView(this, LinearLayout.LayoutParams(app.dp(40), app.dp(40))) }
            app.text(empty, app.getString(R.string.empty_title), 22f).typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            app.text(empty, app.getString(R.string.empty), 15f)
            app.button(empty, R.string.find_cameras) { app.navigate(DiscoveryScreen(app)) }.also { app.primary(it) }
            app.button(empty, R.string.add_manually) { app.editCamera() }
        }
        val cards = mutableListOf<Triple<CameraProfile, LinearLayout, VideoPane?>>()
        for (camera in app.profiles) {
            val card = app.column().apply { background = app.surface(); setPadding(0, 0, 0, app.dp(10)); clipToOutline = true }
            content.addView(card, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = app.dp(16) })
            val preview = AspectFrame(app)
            card.addView(preview, LinearLayout.LayoutParams(-1, -2))
            val video = if (camera.id in app.connected && app.credentials[camera.id] != null) app.video().also {
                preview.addView(it, FrameLayout.LayoutParams(-1, -1)); videos.add(it)
            } else null
            if (video == null) {
                preview.background = app.surface(0xff202b25.toInt(), 0)
                val offline = LinearLayout(app).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER }
                preview.addView(offline, FrameLayout.LayoutParams(-1, -1))
                ImageView(app).apply { setImageResource(R.drawable.ic_camera); imageTintList = ColorStateList.valueOf(0xffa7b8aa.toInt()); offline.addView(this, LinearLayout.LayoutParams(app.dp(32), app.dp(32))) }
                app.text(offline, app.getString(R.string.disconnected), 13f).apply { gravity = Gravity.CENTER; setTextColor(0xffc7d3c9.toInt()) }
            }
            val info = app.column().apply { setPadding(app.dp(16), app.dp(10), app.dp(16), 0) }; card.addView(info)
            val heading = app.row(info)
            app.text(heading, camera.name, 18f).apply { typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL); layoutParams = LinearLayout.LayoutParams(0, -2, 1f) }
            app.icon(heading, R.drawable.ic_more, R.string.more) { menu(camera, heading) }
            app.text(info, camera.host, 13f).setPadding(0, 0, 0, app.dp(8))
            cards.add(Triple(camera, card, video))
            val actions = app.row(info)
            app.button(actions, if (camera.id in app.connected) R.string.stop else R.string.connect) {
                if (camera.id in app.connected) { app.connected.remove(camera.id); show() }
                else app.authenticate(camera) { app.connected.add(camera.id); show() }
            }.also { if (camera.id !in app.connected) app.primary(it) }
            app.icon(actions, R.drawable.ic_expand, R.string.fullscreen) { app.authenticate(camera) { credentials -> app.connected.add(camera.id); app.navigate(EnlargedScreen(app, camera, credentials)) } }

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
    private fun aboutMenu(anchor: View) {
        val menu = PopupMenu(app, anchor)
        menu.menu.add(R.string.about)
        menu.setOnMenuItemClickListener {
            val content = app.column()
            val notice = app.assets.open("THIRD_PARTY_NOTICES.txt").bufferedReader().use { it.readText() }
            app.text(content, notice, 13f).autoLinkMask = android.text.util.Linkify.WEB_URLS
            AlertDialog.Builder(app).setTitle(R.string.about).setView(ScrollView(app).apply { addView(content) }).setPositiveButton(R.string.back, null).show()
            true
        }
        menu.show()
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
