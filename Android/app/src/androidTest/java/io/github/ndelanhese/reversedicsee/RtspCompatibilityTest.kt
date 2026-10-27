package io.github.ndelanhese.reversedicsee

import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Uses AuthenticatedLiveFixtureServer.py through adb reverse, never a real camera. */
@RunWith(AndroidJUnit4::class)
class RtspCompatibilityTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test fun digestHevcPrimaryWithReservedPasswordDecodes() = decode("digestRtspPort", false)
    @Test fun digestHevcSubstreamWithReservedPasswordDecodes() = decode("digestRtspPort", true)
    @Test fun digestHevcSofiaQueryFallbackDecodes() = decode("sofiaRtspPort", false)
    @Test fun audioArrivingBeforeVideoKeepsLivePlaybackRunning() = decode("audioFirstRtspPort", false, 5500)

    private fun decode(argument: String, substream: Boolean, sustainMs: Long = 0) {
        val port = InstrumentationRegistry.getArguments().getString(argument)?.toIntOrNull()
        assertNotNull("Start the synthetic authenticated HEVC peer and pass -e $argument <reversed-port>", port)
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ) as MainActivity
        var pane: VideoPane? = null
        try {
            instrumentation.runOnMainSync {
                activity.navigate(EnlargedScreen(activity,
                    CameraProfile(name = "Synthetic authenticated HEVC", host = "127.0.0.1", port = port!!, substream = substream),
                    Credentials("fixture", "syn:the@tic/?#%&=+")))
                pane = views(activity.window.decorView).filterIsInstance<VideoPane>().first()
            }
            var decoded = 0
            val deadline = SystemClock.elapsedRealtime() + 55000
            while (decoded < 5 && SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(100)
                instrumentation.runOnMainSync { decoded = pane!!.decodedFrames }
            }
            assertTrue("Production VideoPane decoded $decoded frames from $argument (substream=$substream); expected >=5", decoded >= 5)
            instrumentation.runOnMainSync { assertTrue("Decoded live pane lost playback intent", pane!!.intentToPlay) }
            if (sustainMs > 0) {
                val initialFrames = decoded
                val until = SystemClock.elapsedRealtime() + sustainMs
                while (SystemClock.elapsedRealtime() < until) {
                    Thread.sleep(250)
                    instrumentation.runOnMainSync {
                        assertTrue("Audio-leading live stream stopped during sustained playback", pane!!.intentToPlay && pane!!.isPlaying)
                        decoded = pane!!.decodedFrames
                    }
                }
                assertTrue("Audio-leading video stopped advancing: $initialFrames -> $decoded frames", decoded >= initialFrames + 20)
                instrumentation.runOnMainSync {
                    val playerField = VideoPane::class.java.getDeclaredField("player").apply { isAccessible = true }
                    val player = playerField.get(pane) as org.videolan.libvlc.MediaPlayer
                    assertEquals("Live audio output must stay muted", 0, player.volume)
                }
            }
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }

    private fun views(view: View): List<View> = listOf(view) +
        if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
}
