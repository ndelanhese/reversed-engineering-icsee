package io.github.ndelanhese.reversedicsee

import android.app.AlertDialog
import android.app.DatePickerDialog
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.view.MotionEvent
import android.view.View
import android.widget.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicBoolean

class RecordingsScreen(app: MainActivity, private val camera: CameraProfile, private val credentials: Credentials) : CameraScreen(app) {
    private var day = LocalDate.now()
    private var records = JSONArray()
    private var selected = -1
    private var cache: PlaybackCache? = null
    private var index: JSONObject? = null
    private var video: VideoPane? = null
    private var playScope = WorkScope()
    private var conversionCancelled = AtomicBoolean(false)
    private var exportCancelled = AtomicBoolean(false)
    private var generation = 0
    private val pendingExports = mutableSetOf<PendingExport>()
    private var complete = true
    private var active = true
    private var status: TextView? = null
    private var movieArea: LinearLayout? = null
    private val ui = Handler(Looper.getMainLooper())
    private var ticker: Runnable? = null
    override fun show() {
        active = true
        showListing(complete)
        if (!queried) load()
    }
    private var queried = false
    private fun chooseDay(value: LocalDate) {
        stopPlayback(); scope.close(); scope = WorkScope(); loading = false; complete = true; day = value; records = JSONArray(); queried = false; show()
    }
    private var loading = false
    private fun load() {
        if (loading) return
        loading = true; status?.setText(R.string.loading)
        scope.run(camera.request("recordings", credentials).put("day", day.toString()), { result ->
            loading = false; queried = true
            val r = result as JSONObject; records = r.getJSONArray("records")
            complete = r.optBoolean("complete"); showListing(complete)
        }, { loading = false; status?.text = errorMessage(app, it) })
    }
    private fun showListing(complete: Boolean) {
        // Avoid treating a successfully empty listing as a request to load again.
        val root = app.frame(camera.name)
        app.text(root, app.getString(R.string.sd_history), 14f)
        val body = app.scroll(root)
        status = app.text(body, app.getString(if (complete) R.string.temporary else R.string.partial), 13f)
        val dateRow = app.row(body)
        app.icon(dateRow, R.drawable.ic_back, R.string.previous) { chooseDay(day.minusDays(1)) }
        app.button(dateRow, day.toString()) { DatePickerDialog(app, { _, y, m, d -> chooseDay(LocalDate.of(y, m + 1, d)) }, day.year, day.monthValue - 1, day.dayOfMonth).show() }
        app.icon(dateRow, R.drawable.ic_back, R.string.next) { chooseDay(day.plusDays(1)) }.rotation = 180f
        app.button(body, R.string.choose_date) { calendarDialog() }
        val actions = app.row(body)
        app.button(actions, R.string.refresh) { load() }; app.button(actions, R.string.go_time) { goTime() }
        movieArea = app.column().also { body.addView(it) }; renderMovie()
        app.text(body, app.getString(R.string.camera_time), 13f)
        body.addView(DayTimeline(app, day, records) { t -> val i = findRecording(t); if (i >= 0) play(i) }, LinearLayout.LayoutParams(-1, app.dp(54)))
        val list = ListView(app)
        list.adapter = ArrayAdapter(app, android.R.layout.simple_list_item_1, (0 until records.length()).map { i -> val r = records.getJSONObject(i); "${r.getString("begin")} – ${r.getString("end").substringAfter(' ')}" })
        list.setOnItemClickListener { _, _, position, _ -> play(position) }; body.addView(list, LinearLayout.LayoutParams(-1, if (records.length() == 0) 0 else app.dp(300)))
        if (records.length() == 0) app.text(body, app.getString(R.string.no_recordings))
    }
    private fun calendarDialog() {
        val panel = app.column(); val status = app.text(panel, app.getString(R.string.loading))
        val dialog = AlertDialog.Builder(app).setTitle("${day.year}-${day.monthValue}").setView(ScrollView(app).apply { addView(panel) }).setNegativeButton(R.string.cancel, null).create()
        dialog.show()
        scope.run(camera.request("calendar", credentials).put("year", day.year).put("month", day.monthValue), { result ->
            status.text = app.getString(R.string.choose_date)
            val days = (result as JSONObject).getJSONArray("days"); val grid = GridLayout(app).apply { columnCount = 5 }; panel.addView(grid)
            for (i in 0 until days.length()) { val d = days.getInt(i); grid.addView(Button(app).apply { text = "$d •"; minWidth = 0; minimumWidth = 0; setOnClickListener { dialog.dismiss(); chooseDay(day.withDayOfMonth(d)) } }, GridLayout.LayoutParams().apply { width = app.dp(48); height = app.dp(48) }) }
        }, { status.text = errorMessage(app, it) })
    }
    private fun goTime() {
        val form = app.column(); val time = app.edit(form, R.string.minute_of_day, "00:00")
        AlertDialog.Builder(app).setTitle(R.string.go_time).setView(form).setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.play) { _, _ ->
            val t = runCatching { day.atTime(java.time.LocalTime.parse(time.text.toString(), DateTimeFormatter.ofPattern("HH:mm"))) }.getOrNull()
            if (t == null) error("invalid_input") else { val i = findRecording(t); if (i < 0) app.message(app.getString(R.string.no_recordings)) else play(i, t) }
        }.show()
    }
    private fun findRecording(time: LocalDateTime): Int = (0 until records.length()).firstOrNull { i ->
        val r = records.getJSONObject(i); time >= clock(r.getString("begin")) && time < clock(r.getString("end"))
    } ?: -1
    private fun clock(value: String): LocalDateTime = LocalDateTime.parse(value, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"))
    private fun stopPlayback() {
        exportCancelled.set(true)
        pendingExports.forEach { it.close() }; pendingExports.clear()
        generation++; playScope.close(); playScope = WorkScope(); conversionCancelled.set(true)
        ticker?.let { ui.removeCallbacks(it) }; ticker = null
        video?.close(); video = null; cache?.close(); cache = null; index = null
    }
    private fun play(position: Int, seekTime: LocalDateTime? = null) {
        stopPlayback(); selected = position
        if (position !in 0 until records.length()) return
        val recording = records.getJSONObject(position)
        val own = PlaybackCache(app); cache = own
        val expected = generation; val cancelled = AtomicBoolean(false); conversionCancelled = cancelled
        status?.setText(R.string.download); renderMovie()
        playScope.run(camera.request("download", credentials).put("recording", recording).put("path", own.original.path), {
            status?.setText(R.string.preparing)
            playScope.run(JSONObject().put("op", "index_media").put("path", own.original.path), { result ->
                val metadata = result as JSONObject
                WorkScope.workers.execute {
                    val converted = runCatching {
                        val audio = RecordingMovie.create(own.original, own.movie, metadata, cancelled)
                        if (RecordingMovie.verify(own.movie, cancelled) != metadata.getJSONArray("samples").length()) throw CameraFailure("invalid_media")
                        audio
                    }
                    ui.post {
                        if (expected != generation || !active) { own.close(); return@post }
                        converted.fold({ audio ->
                            index = metadata; metadata.put("hasAudio", audio)
                            status?.text = app.getString(if (audio || metadata.getJSONArray("audio").length() == 0) R.string.timing_notice else R.string.video_only)
                            renderMovie()
                            if (seekTime != null) {
                                val seconds = java.time.Duration.between(clock(recording.getString("begin")), seekTime).seconds
                                val seek = Runnable { if (expected == generation) video?.seek(seconds * 1000) }; ui.postDelayed(seek, 700)
                            }
                        }, { failed((it as? CameraFailure)?.code ?: "unsupported_video") })
                    }
                }
            }, ::failed)
        }, ::failed)
    }
    private fun failed(code: String) { stopPlayback(); status?.text = errorMessage(app, code); renderMovie() }
    private fun renderMovie() {
        val area = movieArea ?: return
        ticker?.let { ui.removeCallbacks(it) }; ticker = null
        video?.close(); video = null; area.removeAllViews()
        val own = cache; val metadata = index
        if (own != null && metadata != null && own.movie.exists()) {
            val pane = app.video(); video = pane; area.addView(pane, LinearLayout.LayoutParams(-1, app.dp(250)))
            pane.movie(own.movie) { failed("unsupported_video") }
            val seek = SeekBar(app).apply { max = (metadata.getLong("durationUs") / 1000).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(); area.addView(this) }
            seek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onStartTrackingTouch(view: SeekBar?) = Unit
                override fun onStopTrackingTouch(view: SeekBar?) = Unit
                override fun onProgressChanged(view: SeekBar?, position: Int, fromUser: Boolean) { if (fromUser) pane.seek(position.toLong()) }
            })
            ticker = object : Runnable { override fun run() { if (video === pane && active) { seek.progress = pane.positionMs.toInt(); ui.postDelayed(this, 500) } } }.also { ui.post(it) }
            val actions = app.row(area)
            app.button(actions, "−15s") { pane.seek(pane.positionMs - 15000) }; app.button(actions, R.string.pause) { pane.toggle() }; app.button(actions, "+15s") { pane.seek(pane.positionMs + 15000) }
            val speed = Spinner(app); val rates = listOf(0.5f, 1f, 2f, 4f); speed.adapter = ArrayAdapter(app, android.R.layout.simple_spinner_dropdown_item, rates.map { "${it}×" }); area.addView(speed); speed.setSelection(1)
            speed.onItemSelectedListener = object : AdapterView.OnItemSelectedListener { override fun onNothingSelected(parent: AdapterView<*>?) = Unit; override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) { pane.rate(rates[position]) } }
            app.button(area, R.string.movie_export) { export(own.movie, "mp4", "video/mp4") }
            app.button(area, R.string.interval_export) { interval(own, metadata) }
        }
        if (selected >= 0) {
            val actions = app.row(area)
            app.button(actions, R.string.previous) { if (selected > 0) play(selected - 1) }.isEnabled = selected > 0
            app.button(actions, R.string.next) { if (selected + 1 < records.length()) play(selected + 1) }.isEnabled = selected + 1 < records.length()
            app.button(area, R.string.original_export) { original() }
        }
    }
    private fun original() {
        val own = cache
        if (own != null && index != null && own.movie.exists() && own.original.exists()) { export(own.original, "xm", "application/octet-stream"); return }
        if (selected !in 0 until records.length()) return
        val recording = records.getJSONObject(selected)
        app.document("recording.xm", "application/octet-stream") { uri ->
            if (uri == null) return@document
            val pending = PendingExport(PlaybackCache(app)) { DocumentsContract.deleteDocument(app.contentResolver, uri) }
            pendingExports.add(pending)
            status?.setText(R.string.download)
            pending.scope.run(camera.request("download", credentials).put("recording", recording).put("path", pending.cache.original.path), {
                copy(pending.cache.original, uri) { saved ->
                    if (saved) pending.committed() else pending.close()
                    ui.post { pendingExports.remove(pending) }
                }
            }, { pending.close(); pendingExports.remove(pending); error(it) })
        }
    }
    private fun export(file: File, extension: String, mime: String, cleanup: () -> Unit = {}) {
        app.document("recording.$extension", mime) { uri -> if (uri == null) cleanup() else copy(file, uri) { cleanup() } }
    }
    private fun copy(file: File, uri: android.net.Uri, cleanup: (Boolean) -> Unit) {
        val cancelled = AtomicBoolean(false); exportCancelled = cancelled
        WorkScope.workers.execute {
            val result = runCatching {
                file.inputStream().use { input -> app.contentResolver.openOutputStream(uri, "wt")!!.use { output ->
                    val bytes = ByteArray(64 * 1024)
                    while (true) { if (cancelled.get()) throw CameraFailure("cancelled"); val n = input.read(bytes); if (n < 0) break; output.write(bytes, 0, n) }
                } }
            }
            if (result.isFailure) runCatching { DocumentsContract.deleteDocument(app.contentResolver, uri) }
            cleanup(result.isSuccess && !cancelled.get())
            ui.post { if (active && !cancelled.get()) if (result.isSuccess) app.message(app.getString(R.string.exported)) else error("file_io") }
        }
    }
    private fun interval(own: PlaybackCache, metadata: JSONObject) {
        val form = app.column(); val from = app.edit(form, R.string.start_seconds, "${(video?.positionMs ?: 0) / 1000}"); val to = app.edit(form, R.string.end_seconds, "${metadata.getLong("durationUs") / 1_000_000}")
        app.text(form, app.getString(R.string.interval_notice), 13f)
        AlertDialog.Builder(app).setTitle(R.string.interval_export).setView(form).setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.apply) { _, _ ->
            val bounds = runCatching { RecordingMovie.intervalBounds(metadata, (from.text.toString().toDouble() * 1_000_000).toLong(), (to.text.toString().toDouble() * 1_000_000).toLong()) }.getOrElse { error("invalid_input"); return@setPositiveButton }
            app.confirm(app.getString(R.string.interval_export), "${bounds.first / 1_000_000.0}s – ${bounds.second / 1_000_000.0}s") {
                val file = File(own.directory, "trim-${java.util.UUID.randomUUID()}.mp4"); val expected = generation; val cancelled = conversionCancelled
                WorkScope.workers.execute {
                    val result = runCatching { RecordingMovie.trim(own.movie, file, bounds.first, bounds.second, cancelled) }
                    ui.post { if (expected != generation || !active) { file.delete(); return@post }; result.fold({ export(file, "mp4", "video/mp4") { file.delete() } }, { file.delete(); error("file_io") }) }
                }
            }
        }.show()
    }
    override fun pause() {
        active = false; loading = false; super.pause()
        ticker?.let { ui.removeCallbacks(it) }; ticker = null; video?.close(); video = null
        if (!app.pickingExport) stopPlayback()
    }
    override fun resume() { scope = WorkScope(); active = true; showListing(complete) }
    override fun close() { app.pickingExport = false; pause() }
}

class DayTimeline(context: android.content.Context, private val day: LocalDate, private val records: JSONArray, private val selected: (LocalDateTime) -> Unit) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        paint.color = context.getColor(R.color.ui_timeline_track); canvas.drawRect(0f, 0f, width.toFloat(), height * .55f, paint)
        paint.color = context.getColor(R.color.ui_accent)
        val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
        val origin = day.atStartOfDay()
        for (i in 0 until records.length()) { val r = records.getJSONObject(i); val begin = LocalDateTime.parse(r.getString("begin"), formatter); val end = LocalDateTime.parse(r.getString("end"), formatter)
            val a = java.time.Duration.between(origin, begin).seconds.coerceIn(0, 86400) / 86400f * width
            val b = java.time.Duration.between(origin, end).seconds.coerceIn(0, 86400) / 86400f * width
            canvas.drawRect(a, 0f, b, height * .55f, paint)
        }
        paint.color = context.getColor(R.color.ui_timeline_label); paint.textSize = 11 * resources.displayMetrics.scaledDensity
        canvas.drawText("00:00", 0f, height * .9f, paint); canvas.drawText("12:00", width * .45f, height * .9f, paint); canvas.drawText("24:00", width * .86f, height * .9f, paint)
    }
    override fun onTouchEvent(event: MotionEvent): Boolean { if (event.action == MotionEvent.ACTION_UP) { performClick(); selected(day.atStartOfDay().plusSeconds((event.x / width * 86400).toLong().coerceIn(0, 86399))) }; return true }
    override fun performClick(): Boolean { super.performClick(); return true }
}
