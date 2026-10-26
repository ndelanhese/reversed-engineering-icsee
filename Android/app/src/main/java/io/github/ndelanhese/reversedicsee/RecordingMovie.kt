package io.github.ndelanhese.reversedicsee

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

object RecordingMovie {
    fun verify(file: File, cancelled: AtomicBoolean): Int {
        val extractor = android.media.MediaExtractor()
        var decoder: MediaCodec? = null
        try {
            extractor.setDataSource(file.path)
            val track = (0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true } ?: throw CameraFailure("unsupported_video")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!); decoder = codec
            codec.configure(format, null, null, 0); codec.start()
            var inputEnd = false; var frames = 0; var submitted = 0
            val info = MediaCodec.BufferInfo(); val deadline = System.nanoTime() + 120_000_000_000L
            while (true) {
                checkCancelled(cancelled)
                if (System.nanoTime() >= deadline) throw CameraFailure("timeout")
                if (!inputEnd) {
                    val slot = codec.dequeueInputBuffer(1000)
                    if (slot >= 0) {
                        val data = codec.getInputBuffer(slot)!!; data.clear()
                        val n = extractor.readSampleData(data, 0)
                        if (n < 0) { codec.queueInputBuffer(slot, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputEnd = true }
                        else { codec.queueInputBuffer(slot, 0, n, extractor.sampleTime, 0); submitted++; extractor.advance() }
                    }
                }
                val output = codec.dequeueOutputBuffer(info, 1000)
                if (output >= 0) {
                    if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) frames++
                    val ended = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    codec.releaseOutputBuffer(output, false)
                    if (ended) { if (frames == 0 || frames != submitted) throw CameraFailure("invalid_media"); return frames }
                }
            }
        } finally { extractor.release(); decoder?.let { runCatching { it.stop() }; it.release() } }
    }
    /** Native XM index is bounded; compressed frames stay in the source file. */
    fun create(source: File, destination: File, index: JSONObject, cancelled: AtomicBoolean): Boolean {
        check(!destination.exists())
        val muxer = MediaMuxer(destination.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false
        var success = false
        try {
            val format = MediaFormat.createVideoFormat(index.getString("mime"), index.getInt("width"), index.getInt("height"))
            val csd = index.getJSONArray("csd")
            for (i in 0 until csd.length()) format.setByteBuffer("csd-$i", ByteBuffer.wrap(Base64.decode(csd.getString(i), Base64.NO_WRAP)))
            val video = muxer.addTrack(format)
            // Audio is encoded in a private temporary AAC file before adding its track.
            val audioFile = File(destination.parentFile, "audio.m4a")
            val hasAudio = index.has("audioCodec") && !index.isNull("audioCodec") && index.getJSONArray("audio").length() > 0
            val encodedAudio = if (hasAudio) runCatching { encodeAudio(source, audioFile, index, cancelled) }.getOrElse { if (cancelled.get()) throw CameraFailure("cancelled"); false } else false
            val audioExtractor = if (encodedAudio) android.media.MediaExtractor().apply { setDataSource(audioFile.path); selectTrack(0) } else null
            val audio = audioExtractor?.let { muxer.addTrack(it.getTrackFormat(0)) }
            muxer.start(); started = true
            RandomAccessFile(source, "r").use { input ->
                val samples = index.getJSONArray("samples")
                val info = MediaCodec.BufferInfo()
                for (i in 0 until samples.length()) {
                    checkCancelled(cancelled)
                    val sample = samples.getJSONArray(i)
                    val length = sample.getInt(1)
                    require(length in 1..16 * 1024 * 1024)
                    val bytes = ByteArray(length)
                    input.seek(sample.getLong(0)); input.readFully(bytes)
                    info.set(0, bytes.size, sample.getLong(2), if (sample.getBoolean(3)) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    muxer.writeSampleData(video, ByteBuffer.wrap(bytes), info)
                }
            }
            if (audioExtractor != null && audio != null) try {
                val buffer = ByteBuffer.allocate(64 * 1024)
                val info = MediaCodec.BufferInfo()
                while (true) {
                    checkCancelled(cancelled)
                    buffer.clear(); val n = audioExtractor.readSampleData(buffer, 0); if (n < 0) break
                    info.set(0, n, audioExtractor.sampleTime, if (audioExtractor.sampleFlags and android.media.MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    muxer.writeSampleData(audio, buffer, info); audioExtractor.advance()
                }
            } finally { audioExtractor.release() }
            muxer.stop(); started = false; success = true
            return encodedAudio
        } finally {
            if (started) runCatching { muxer.stop() }
            muxer.release()
            File(destination.parentFile, "audio.m4a").delete()
            if (!success) destination.delete()
        }
    }
    private fun encodeAudio(source: File, destination: File, index: JSONObject, cancelled: AtomicBoolean): Boolean {
        val format = MediaFormat.createAudioFormat("audio/mp4a-latm", 8000, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 32000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val codec = MediaCodec.createEncoderByType("audio/mp4a-latm")
        val muxer = MediaMuxer(destination.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1; var started = false; var finished = false
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); codec.start()
            val packets = index.getJSONArray("audio"); val codecId = index.getInt("audioCodec")
            RandomAccessFile(source, "r").use { input ->
                var packet = 0; var packetOffset = 0; var sampleCount = 0L; var inputEnd = false
                val info = MediaCodec.BufferInfo(); val deadline = System.nanoTime() + 120_000_000_000L
                while (!finished) {
                    checkCancelled(cancelled)
                    if (System.nanoTime() > deadline) throw CameraFailure("timeout")
                    if (!inputEnd) {
                        val slot = codec.dequeueInputBuffer(1000)
                        if (slot >= 0) {
                            val buffer = codec.getInputBuffer(slot)!!; buffer.clear(); val time = sampleCount * 1_000_000 / 8000
                            while (packet < packets.length() && buffer.remaining() >= 2) {
                                val p = packets.getJSONArray(packet); val available = p.getInt(1) - packetOffset
                                val count = minOf(available, buffer.remaining() / 2)
                                val bytes = ByteArray(count); input.seek(p.getLong(0) + packetOffset); input.readFully(bytes)
                                for (b in bytes) { val sample = g711(b.toInt() and 255, codecId); buffer.put((sample and 255).toByte()); buffer.put((sample shr 8).toByte()) }
                                packetOffset += count; sampleCount += count
                                if (packetOffset == p.getInt(1)) { packet++; packetOffset = 0 }
                            }
                            val length = buffer.position(); inputEnd = packet >= packets.length()
                            codec.queueInputBuffer(slot, 0, length, time, if (inputEnd) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                        }
                    }
                    when (val slot = codec.dequeueOutputBuffer(info, 1000)) {
                        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { track = muxer.addTrack(codec.outputFormat); muxer.start(); started = true }
                        in 0..Int.MAX_VALUE -> {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                check(started); val data = codec.getOutputBuffer(slot)!!; data.position(info.offset); data.limit(info.offset + info.size); muxer.writeSampleData(track, data, info)
                            }
                            finished = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            codec.releaseOutputBuffer(slot, false)
                        }
                    }
                }
            }
            muxer.stop(); started = false
            return finished
        } finally {
            runCatching { codec.stop() }; codec.release()
            if (started) runCatching { muxer.stop() }; muxer.release()
            if (!finished) destination.delete()
        }
    }
    fun g711(code: Int, codec: Int): Int = if (codec == 14) {
        val v = code xor 0x55; val exponent = v shr 4 and 7
        var magnitude = (v and 15) shl 4; magnitude += if (exponent == 0) 8 else 264
        if (exponent > 1) magnitude = magnitude shl (exponent - 1)
        if (v and 128 == 0) -magnitude else magnitude
    } else {
        val v = code.inv() and 255; val magnitude = (((v and 15) shl 3) + 132) shl (v shr 4 and 7)
        if (v and 128 == 0) magnitude - 132 else 132 - magnitude
    }
    private fun checkCancelled(cancelled: AtomicBoolean) { if (cancelled.get()) throw CameraFailure("cancelled") }

    /** Passthrough trim expands to independent keyframe boundaries. */
    fun intervalBounds(index: JSONObject, fromUs: Long, toUs: Long): Pair<Long, Long> {
        val duration = index.getLong("durationUs"); require(fromUs in 0 until toUs && toUs <= duration)
        val samples = index.getJSONArray("samples")
        var begin = 0L; var end = duration
        for (i in 0 until samples.length()) { val s = samples.getJSONArray(i); if (!s.getBoolean(3)) continue; val t = s.getLong(2); if (t <= fromUs) begin = t; if (t >= toUs) { end = t; break } }
        return begin to end
    }
    fun trim(source: File, destination: File, begin: Long, end: Long, cancelled: AtomicBoolean) {
        check(!destination.exists())
        val extractor = android.media.MediaExtractor()
        val muxer = MediaMuxer(destination.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false; var success = false
        try {
            extractor.setDataSource(source.path)
            val tracks = (0 until extractor.trackCount).associateWith { muxer.addTrack(extractor.getTrackFormat(it)) }
            tracks.keys.forEach { extractor.selectTrack(it) }
            extractor.seekTo(begin, android.media.MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            muxer.start(); started = true
            val data = ByteBuffer.allocate(16 * 1024 * 1024); val info = MediaCodec.BufferInfo()
            while (true) {
                checkCancelled(cancelled)
                val time = extractor.sampleTime; if (time < 0 || time >= end) break
                data.clear(); val n = extractor.readSampleData(data, 0); if (n < 0) break
                if (time >= begin) { info.set(0, n, time - begin, if (extractor.sampleFlags and android.media.MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0); muxer.writeSampleData(tracks.getValue(extractor.sampleTrackIndex), data, info) }
                extractor.advance()
            }
            muxer.stop(); started = false; success = true
        } finally { extractor.release(); if (started) runCatching { muxer.stop() }; muxer.release(); if (!success) destination.delete() }
    }
}
