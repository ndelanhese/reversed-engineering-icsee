package io.github.ndelanhese.reversedicsee

import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/** Independent loopback camera peer: delays and partial pagination are intentional. */
class DvripPeer(private val delayFirst: Boolean = false, private val partial: Boolean = false, private val calendarMask: Int = 1) : AutoCloseable {
    private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    private val running = AtomicBoolean(true)
    private val first = AtomicBoolean(true)
    private val sockets = java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()
    val queryStarted = CountDownLatch(1)
    val releaseFirst = CountDownLatch(1)
    val secondQuery = CountDownLatch(2)
    val camera = CameraProfile(name = "Synthetic history", host = "127.0.0.1", controlPort = server.localPort)
    init {
        thread(isDaemon = true) {
            while (running.get()) {
                val socket = try { server.accept() } catch (_: Exception) { break }
                sockets.add(socket)
                thread(isDaemon = true) { try { serve(socket) } catch (_: Exception) { } finally { sockets.remove(socket); socket.close() } }
            }
        }
    }
    private fun serve(socket: Socket) {
        socket.soTimeout = 5000
        val input = DataInputStream(socket.getInputStream())
        while (running.get()) {
            val header = ByteArray(20); input.readFully(header)
            val frame = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val message = frame.getShort(14).toInt() and 65535
            val size = frame.getInt(16); require(size in 1..2097152)
            val bytes = ByteArray(size); input.readFully(bytes)
            val body = JSONObject(String(bytes).trimEnd('\u0000', '\r', '\n'))
            val response = when (message) {
                1000 -> JSONObject().put("Ret", 100).put("SessionID", "0x0000002a")
                1440 -> {
                    queryStarted.countDown(); secondQuery.countDown()
                    if (delayFirst && first.compareAndSet(true, false)) releaseFirst.await(5, java.util.concurrent.TimeUnit.SECONDS)
                    val date = body.getJSONObject("OPFileQuery").getString("EndTime").substring(0, 10)
                    JSONObject().put("Ret", if (partial) 111 else 110).put("OPFileQuery", JSONArray().put(JSONObject().put("FileName", "fixture.xm").put("BeginTime", "$date 00:00:00").put("EndTime", "$date 00:05:00").put("FileLength", 1)))
                }
                1446 -> JSONObject().put("Ret", 100).put("OPSCalendar", JSONObject().put("Mask", calendarMask))
                else -> JSONObject().put("Ret", 100)
            }
            val payload = response.toString().toByteArray()
            val reply = ByteBuffer.allocate(20 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
            reply.put(byteArrayOf(255.toByte(), 0, 0, 0)); reply.putInt(42); reply.putInt(frame.getInt(8) or 1)
            reply.put(byteArrayOf(1, 0)); reply.putShort((message + 1).toShort()); reply.putInt(payload.size); reply.put(payload)
            socket.getOutputStream().write(reply.array())
        }
    }
    override fun close() { running.set(false); releaseFirst.countDown(); server.close(); sockets.forEach { runCatching { it.close() } } }
}
