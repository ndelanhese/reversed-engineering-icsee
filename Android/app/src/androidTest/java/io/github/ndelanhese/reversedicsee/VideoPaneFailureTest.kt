package io.github.ndelanhese.reversedicsee

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

@RunWith(AndroidJUnit4::class)
class VideoPaneFailureTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    private class RtspFailurePeer(private val unauthorized: Boolean) : AutoCloseable {
        private val server = ServerSocket(0, 8, java.net.InetAddress.getByName("127.0.0.1"))
        private val clients = java.util.Collections.synchronizedList(mutableListOf<Socket>())
        val accepted = CountDownLatch(1)
        val port get() = server.localPort
        init {
            thread(isDaemon = true) {
                try {
                    while (!server.isClosed) {
                        val client = server.accept(); clients.add(client); accepted.countDown()
                        thread(isDaemon = true) {
                            try {
                                val input = client.getInputStream().bufferedReader()
                                while (input.readLine() != null) {
                                    var sequence = "1"
                                    while (true) {
                                        val line = input.readLine() ?: return@thread
                                        if (line.isEmpty()) break
                                        if (line.startsWith("CSeq:", true)) sequence = line.substringAfter(':').trim()
                                    }
                                    if (unauthorized) {
                                        client.getOutputStream().write(("RTSP/1.0 401 Unauthorized\r\nCSeq: $sequence\r\n" +
                                            "WWW-Authenticate: Basic realm=\"synthetic\"\r\nContent-Length: 0\r\n\r\n").toByteArray())
                                    }
                                }
                            } catch (_: java.io.IOException) { }
                        }
                    }
                } catch (_: java.io.IOException) { }
            }
        }
        override fun close() {
            server.close()
            synchronized(clients) { clients.forEach { it.close() } }
        }
    }

    private fun onUi(block: () -> Unit) {
        val done = CountDownLatch(1)
        var failure: Throwable? = null
        Handler(Looper.getMainLooper()).post { try { block() } catch (error: Throwable) { failure = error } finally { done.countDown() } }
        assertTrue("Player blocked the main thread", done.await(3, TimeUnit.SECONDS))
        failure?.let { throw it }
    }
    private fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
    private fun withPane(peer: RtspFailurePeer, block: (VideoPane) -> Unit) {
        val app = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        var pane: VideoPane? = null
        try {
            onUi {
                activity.navigate(EnlargedScreen(activity, CameraProfile(name = "Synthetic failure", host = "127.0.0.1", port = peer.port), Credentials("fixture", "synthetic")))
                pane = views(activity.window.decorView).filterIsInstance<VideoPane>().first()
            }
            assertTrue("LibVLC did not contact the RTSP peer", peer.accepted.await(5, TimeUnit.SECONDS))
            block(pane!!)
        } finally { onUi { activity.finish() } }
    }
    @Test fun rejectedRtspCredentialsDoNotLeaveConnecting() {
        RtspFailurePeer(unauthorized = true).use { peer -> withPane(peer) { pane ->
            awaitTerminal(pane, 45000)
        } }
    }
    @Test fun silentRtspPeerCanBeStoppedWithoutBlockingTheUi() {
        RtspFailurePeer(unauthorized = false).use { peer -> withPane(peer) { pane ->
            onUi { pane.suspendLive(); assertFalse(pane.intentToPlay); assertFalse(pane.isPlaying) }
        } }
    }
    @Test fun silentRtspPeerHasABoundedConnectionDeadline() {
        RtspFailurePeer(unauthorized = false).use { peer -> withPane(peer) { pane ->
            awaitTerminal(pane, 45000)
        } }
    }
    @Test fun replacingASilentRtspConnectionDoesNotBlockOrReviveTheOldPlayer() {
        RtspFailurePeer(unauthorized = false).use { old -> withPane(old) { pane ->
            RtspFailurePeer(unauthorized = true).use { replacement ->
                onUi { pane.live(CameraProfile(name = "Replacement", host = "127.0.0.1", port = replacement.port), Credentials("fixture", "synthetic")) }
                assertTrue(replacement.accepted.await(5, TimeUnit.SECONDS))
                awaitTerminal(pane, 45000)
                onUi { pane.suspendLive() }
                old.close()
                Thread.sleep(200)
                onUi {
                    assertFalse(pane.isPlaying)
                    assertFalse(pane.intentToPlay)
                    assertEquals(pane.context.getString(R.string.disconnected), views(pane).filterIsInstance<TextView>().first().text)
                }
            }
        } }
    }
    private fun awaitTerminal(pane: VideoPane, timeout: Long) {
        val deadline = android.os.SystemClock.elapsedRealtime() + timeout
        var terminal = false
        while (!terminal && android.os.SystemClock.elapsedRealtime() < deadline) {
            onUi {
                val status = views(pane).filterIsInstance<TextView>().first()
                terminal = status.visibility == View.VISIBLE && status.text != pane.context.getString(R.string.connecting)
            }
            if (!terminal) Thread.sleep(100)
        }
        assertTrue("RTSP failure stayed Connecting past its deadline", terminal)
    }
}
