package io.github.ndelanhese.reversedicsee

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(AndroidJUnit4::class)
class DeviceTest {
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun credentialVaultSurvivesNewInstanceAndDoesNotStorePlaintext() {
        val id = "synthetic-device-test"
        val credentials = Credentials("fixture", "synthetic-password-only")
        val vault = CredentialVault(app)
        try {
            vault.save(id, credentials)
            assertEquals(credentials, CredentialVault(app).load(id))
            val blob = app.getSharedPreferences("credentials", 0).getString(id, "")!!
            assertFalse(blob.contains(credentials.password)); assertFalse(blob.contains(credentials.username))
        } finally { vault.remove(id) }
    }
    @Test fun privatePlaybackCacheIsRemovedOnClose() {
        val cache = PlaybackCache(app)
        cache.original.writeBytes(byteArrayOf(1, 2, 3))
        assertTrue(cache.original.exists()); cache.close(); assertFalse(cache.directory.exists())
    }
    @Test fun rustJniLoadsAndCancellationDoesNotLeakTheToken() {
        val token = NativeCore.newToken(); assertTrue(token > 0)
        NativeCore.cancel(token)
        val r = JSONObject(NativeCore.call(token, JSONObject().put("op", "settings_catalog").toString()))
        assertEquals("cancelled", r.getString("error"))
        val next = NativeCore.newToken(); val catalog = JSONObject(NativeCore.call(next, "{\"op\":\"settings_catalog\"}"))
        assertTrue(catalog.getJSONArray("ok").length() > 50)
    }
    @Test fun syntheticXmBecomesSeekableNativeMovie() {
        val own = PlaybackCache(app)
        try {
            val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("pattern.xm").use { it.readBytes() }
            own.original.writeBytes(bytes)
            val token = NativeCore.newToken()
            val r = JSONObject(NativeCore.call(token, JSONObject().put("op", "index_media").put("path", own.original.path).toString()))
            assertFalse(r.toString(), r.has("error"))
            RecordingMovie.create(own.original, own.movie, r.getJSONObject("ok"), AtomicBoolean(false))
            assertEquals(45, RecordingMovie.verify(own.movie, AtomicBoolean(false)))
            assertTrue(own.movie.length() > 1000)
            val extractor = android.media.MediaExtractor()
            try { extractor.setDataSource(own.movie.path); assertEquals(1, extractor.trackCount); assertEquals("video/avc", extractor.getTrackFormat(0).getString("mime")) } finally { extractor.release() }
        } finally { own.close() }
    }
    @Test fun hevcAndG711AudioAreConvertedAndFullyDecoded() {
        for (name in listOf("hevc", "audio")) {
            val own = PlaybackCache(app)
            try {
                InstrumentationRegistry.getInstrumentation().context.assets.open("$name.xm").use { input -> own.original.outputStream().use { input.copyTo(it) } }
                val token = NativeCore.newToken()
                val result = JSONObject(NativeCore.call(token, JSONObject().put("op", "index_media").put("path", own.original.path).toString()))
                assertFalse(result.toString(), result.has("error"))
                val metadata = result.getJSONObject("ok")
                val audio = RecordingMovie.create(own.original, own.movie, metadata, AtomicBoolean(false))
                assertEquals(name == "audio", audio)
                assertEquals(45, RecordingMovie.verify(own.movie, AtomicBoolean(false)))
                val extractor = android.media.MediaExtractor()
                try { extractor.setDataSource(own.movie.path); assertEquals(if (audio) 2 else 1, extractor.trackCount) } finally { extractor.release() }
            } finally { own.close() }
        }
    }
    @Test fun liveSurfaceDecodesRtspAndClosesInBackground() {
        val args = InstrumentationRegistry.getArguments()
        val port = args.getString("rtspPort")?.toIntOrNull()
        org.junit.Assume.assumeTrue("Loopback RTSP peer required", port != null)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(android.content.Intent(app, MainActivity::class.java).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        var pane: VideoPane? = null
        instrumentation.runOnMainSync { activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
        awaitUi { activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT }
        instrumentation.runOnMainSync {
            activity.navigate(EnlargedScreen(activity, CameraProfile(name = "Synthetic RTSP", host = "127.0.0.1", port = port!!), Credentials("fixture", "synthetic")))
            fun find(view: android.view.View): VideoPane? {
                if (view is VideoPane) return view
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) find(view.getChildAt(i))?.let { return it }
                return null
            }
            pane = find(activity.window.decorView)
        }
        try {
            var decoded = 0; val deadline = System.currentTimeMillis() + 20000
            while (decoded < 5 && System.currentTimeMillis() < deadline) { Thread.sleep(100); instrumentation.runOnMainSync { decoded = pane!!.decodedFrames } }
            assertTrue("No frames decoded by production LibVLC surface", decoded >= 5)
            val beforeRotation = decoded
            instrumentation.runOnMainSync { activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            awaitUi { activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE }
            awaitUi { pane!!.decodedFrames > beforeRotation + 3 }
            instrumentation.runOnMainSync { activity.startActivity(android.content.Intent(android.content.Intent.ACTION_MAIN).addCategory(android.content.Intent.CATEGORY_HOME).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) }
            Thread.sleep(700)
            instrumentation.runOnMainSync { assertFalse(pane!!.intentToPlay); assertFalse(pane!!.isPlaying) }
            println("LibVLC ${org.videolan.libvlc.LibVLC.version()} ${org.videolan.libvlc.LibVLC.changeset()}")
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
    private fun activity(): MainActivity = InstrumentationRegistry.getInstrumentation().startActivitySync(android.content.Intent(app, MainActivity::class.java).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
    private fun awaitUi(condition: () -> Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val deadline = System.currentTimeMillis() + 6000
        var ready = false
        while (!ready && System.currentTimeMillis() < deadline) { instrumentation.runOnMainSync { ready = condition() }; if (!ready) Thread.sleep(50) }
        assertTrue("UI condition did not become true", ready)
    }
    private fun views(root: android.view.View): List<android.view.View> = listOf(root) + if (root is android.view.ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
    @Test fun dashboardAllocatesPlayersOnlyForVisibleCameras() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val port = InstrumentationRegistry.getArguments().getString("audioFirstRtspPort")?.toIntOrNull()
        org.junit.Assume.assumeTrue("Synthetic audio-leading RTSP peer required", port != null)
        val activity = activity()
        try {
            instrumentation.runOnMainSync {
                activity.profiles = (1..64).map { CameraProfile(id = "synthetic-$it", name = "Camera $it", host = "127.0.0.1", port = port!!) }
                activity.profiles.forEach { activity.connected.add(it.id); activity.credentials[it.id] = Credentials("fixture", "syn:the@tic/?#%&=+") }
                activity.navigate(DashboardScreen(activity))
            }
            awaitUi { views(activity.window.decorView).filterIsInstance<VideoPane>().any { it.decodedFrames >= 5 } }
            var old: List<VideoPane> = emptyList()
            instrumentation.runOnMainSync {
                old = views(activity.window.decorView).filterIsInstance<VideoPane>()
                assertTrue("Off-screen cameras created ${old.size} video surfaces", old.size <= 4)
                views(activity.window.decorView).filterIsInstance<android.widget.ScrollView>().first().fullScroll(android.view.View.FOCUS_DOWN)
            }
            awaitUi { views(activity.window.decorView).filterIsInstance<VideoPane>().any { it !in old && it.decodedFrames >= 5 } }
            instrumentation.runOnMainSync {
                assertTrue("Off-screen players remained active", old.none { it.intentToPlay || it.isPlaying })
                assertTrue("Too many video surfaces after scroll", views(activity.window.decorView).filterIsInstance<VideoPane>().size <= 4)
            }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
    @Test fun changingDayDuringDelayedQueryStartsANewQuery() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        DvripPeer(delayFirst = true).use { peer ->
            val activity = activity()
            try {
                instrumentation.runOnMainSync { activity.navigate(RecordingsScreen(activity, peer.camera, Credentials("fixture", "synthetic"))) }
                assertTrue(peer.queryStarted.await(4, java.util.concurrent.TimeUnit.SECONDS))
                instrumentation.runOnMainSync { views(activity.window.decorView).first { it.contentDescription == activity.getString(R.string.next) }.performClick() }
                assertTrue("Changing date did not start a replacement history query", peer.secondQuery.await(4, java.util.concurrent.TimeUnit.SECONDS))
                awaitUi { views(activity.window.decorView).filterIsInstance<android.widget.ListView>().any { it.adapter.count == 1 } }
            } finally { instrumentation.runOnMainSync { activity.finish() } }
        }
    }
    @Test fun partialHistoryWarningSurvivesPauseAndResume() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        DvripPeer(partial = true).use { peer ->
            val activity = activity()
            try {
                instrumentation.runOnMainSync { activity.navigate(RecordingsScreen(activity, peer.camera, Credentials("fixture", "synthetic"))) }
                fun warning() = views(activity.window.decorView).filterIsInstance<android.widget.TextView>().any { it.text == activity.getString(R.string.partial) }
                awaitUi { warning() }
                instrumentation.runOnMainSync { instrumentation.callActivityOnPause(activity); instrumentation.callActivityOnResume(activity) }
                awaitUi { warning() }
            } finally { instrumentation.runOnMainSync { activity.finish() } }
        }
    }
    @Test fun abandonedOriginalExportCleansDestinationAndCacheWithoutUiCallbacks() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val cache = PlaybackCache(app); cache.original.writeBytes(byteArrayOf(1, 2, 3))
        val deleted = AtomicBoolean(false)
        var owner: PendingExport? = null
        instrumentation.runOnMainSync { owner = PendingExport(cache) { deleted.set(true) }; owner!!.scope.run(JSONObject().put("op", "settings_catalog"), { fail("Retired success callback") }, { fail("Retired error callback") }); owner!!.close() }
        assertTrue("Picker-created destination was not removed", deleted.get()); assertFalse(cache.directory.exists())
    }
    @Test fun committedExportIsPreservedWhenItsScreenOwnerCloses() {
        val cache = PlaybackCache(app); cache.original.writeBytes(byteArrayOf(1, 2, 3))
        val deleted = AtomicBoolean(false)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val owner = PendingExport(cache) { deleted.set(true) }; owner.committed(); owner.close()
        }
        assertFalse(deleted.get()); assertFalse(cache.directory.exists())
    }
    @Test fun controlsPreviewReleasesDecoderWhenScrolledOutsideViewport() {
        val port = InstrumentationRegistry.getArguments().getString("rtspPort")?.toIntOrNull()
        org.junit.Assume.assumeTrue(port != null)
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val activity = activity()
        var pane: VideoPane? = null
        try {
            instrumentation.runOnMainSync { activity.navigate(ControlsScreen(activity, CameraProfile(name = "Synthetic controls", host = "127.0.0.1", port = port!!), Credentials("fixture", "synthetic"))); pane = views(activity.window.decorView).filterIsInstance<VideoPane>().first() }
            awaitUi { pane!!.decodedFrames >= 5 }
            instrumentation.runOnMainSync {
                val scroll = views(activity.window.decorView).filterIsInstance<android.widget.ScrollView>().first()
                (scroll.getChildAt(0) as android.widget.LinearLayout).addView(android.view.View(activity), android.widget.LinearLayout.LayoutParams(-1, activity.dp(1200)))
                scroll.post { scroll.fullScroll(android.view.View.FOCUS_DOWN) }
            }
            awaitUi { !pane!!.intentToPlay && !pane!!.isPlaying }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}
