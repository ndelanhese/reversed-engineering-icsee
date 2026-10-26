package io.github.ndelanhese.reversedicsee

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import org.json.JSONObject
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout
import java.io.File

class VideoPane(context: Context, private val vlc: LibVLC) : FrameLayout(context), AutoCloseable {
    private val video = VLCVideoLayout(context)
    private val status = TextView(context).apply { gravity = Gravity.CENTER; text = context.getString(R.string.disconnected); setTextColor(0xffbfc8d4.toInt()); setBackgroundColor(0xff030507.toInt()) }
    private var player: MediaPlayer? = null
    private var scope = WorkScope()
    private var retired = false
    private val timer = Handler(Looper.getMainLooper())
    private var watchdog: Runnable? = null
    var intentToPlay = false
        private set
    val isPlaying: Boolean get() = player?.isPlaying == true
    val positionMs: Long get() = player?.time ?: 0
    val durationMs: Long get() = player?.length ?: 0
    val decodedFrames: Int get() {
        val media = player?.media ?: return 0
        return try { media.stats?.decodedVideo ?: 0 } finally { media.release() }
    }
    init {
        setBackgroundColor(0xff030507.toInt())
        addView(video, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(status, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }
    fun live(camera: CameraProfile, credentials: Credentials) {
        intentToPlay = true
        startLive(camera, credentials, false)
    }
    private fun startLive(camera: CameraProfile, credentials: Credentials, compatibility: Boolean) {
        scope.run(camera.request("rtsp", credentials).put("compatibility", compatibility), { result ->
            if (!retired) start(Uri.parse((result as JSONObject).getString("uri")), true) {
                if (!compatibility && !retired) startLive(camera, credentials, true)
                else status.text = context.getString(R.string.error_disconnected)
            }
        }, { code -> status.text = errorMessage(context, code) })
    }
    fun movie(file: File, failed: () -> Unit) { intentToPlay = true; start(Uri.fromFile(file), false, failed) }
    private fun start(uri: Uri, live: Boolean, failed: () -> Unit) {
        releasePlayer()
        status.visibility = VISIBLE; status.text = context.getString(R.string.connecting)
        val next = MediaPlayer(vlc)
        player = next
        next.attachViews(video, null, false, false)
        var reachedVideo = false
        next.setEventListener { event ->
            if (!retired && player === next) when (event.type) {
                MediaPlayer.Event.Playing -> { if (!live) { reachedVideo = true; status.visibility = GONE } }
                MediaPlayer.Event.EncounteredError -> { releasePlayer(); status.visibility = VISIBLE; status.text = context.getString(R.string.error_disconnected); if (!live || !reachedVideo) failed() }
                MediaPlayer.Event.EndReached -> { if (live) { status.visibility = VISIBLE; status.text = context.getString(R.string.error_disconnected) } }
            }
        }
        val media = Media(vlc, uri).apply {
            setHWDecoderEnabled(true, false)
            if (live) { addOption(":rtsp-tcp"); addOption(":network-caching=300"); addOption(":no-audio") }
        }
        next.media = media; media.release(); next.play()
        if (live) {
            val began = SystemClock.elapsedRealtime(); var lastFrame: Long? = null; var previousFrames = 0
            watchdog = object : Runnable {
                override fun run() {
                    if (retired || player !== next) return
                    val now = SystemClock.elapsedRealtime(); val frames = decodedFrames
                    if (frames > previousFrames) { previousFrames = frames; lastFrame = now; reachedVideo = true; status.visibility = GONE }
                    if (lastFrame?.let { now - it > 12000 } ?: (now - began > 20000)) {
                        releasePlayer(); status.visibility = VISIBLE; status.text = context.getString(R.string.error_timeout)
                        if (!reachedVideo) failed()
                    } else timer.postDelayed(this, 1000)
                }
            }.also { timer.postDelayed(it, 1000) }
        }
    }
    fun seek(ms: Long) { player?.time = ms.coerceIn(0, durationMs.coerceAtLeast(0)) }
    fun rate(value: Float) { player?.setRate(value) }
    fun toggle() { player?.let { if (it.isPlaying) it.pause() else it.play() } }
    fun suspendLive() { intentToPlay = false; scope.close(); scope = WorkScope(); releasePlayer(); status.visibility = VISIBLE; status.text = context.getString(R.string.disconnected) }
    private fun releasePlayer() {
        watchdog?.let { timer.removeCallbacks(it) }; watchdog = null
        player?.let { p -> player = null; p.setEventListener(null); p.stop(); p.detachViews(); p.release() }
    }
    override fun close() { retired = true; intentToPlay = false; scope.close(); releasePlayer() }
}

fun errorMessage(context: Context, code: String): String {
    val resource = when (code) {
        "invalid_input" -> R.string.error_invalid_input
        "authentication" -> R.string.error_authentication
        "forbidden" -> R.string.error_forbidden
        "unsupported" -> R.string.error_unsupported
        "unreachable" -> R.string.error_unreachable
        "disconnected" -> R.string.error_disconnected
        "invalid_response" -> R.string.error_invalid_response
        "timeout" -> R.string.error_timeout
        "incomplete_transfer" -> R.string.error_incomplete_transfer
        "invalid_media" -> R.string.error_invalid_media
        "configuration_changed" -> R.string.error_configuration_changed
        "reordered_video" -> R.string.error_reordered_video
        "missing_parameters" -> R.string.error_missing_parameters
        "unsupported_video" -> R.string.error_unsupported_video
        "invalid_time" -> R.string.error_invalid_time
        "response_too_large" -> R.string.error_response_too_large
        "conflict" -> R.string.error_conflict
        "read_only" -> R.string.error_read_only
        "write_uncertain" -> R.string.error_write_uncertain
        "verification" -> R.string.error_verification
        "file_io" -> R.string.error_file_io
        "busy" -> R.string.error_busy
        "internal" -> R.string.error_internal
        else -> R.string.error_internal
    }
    return context.getString(resource)
}
