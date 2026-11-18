package dev.aj.fauxnetic

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.BufferedOutputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes the first audio track of any file Android can open (audio or video) to mono 16-bit
 * little-endian PCM at the track's own sample rate, written to [out]. Returns that sample rate.
 * Stops after [maxSeconds] of audio, so a long podcast or video can't fill memory or storage.
 * Runs on a background thread; never on the UI thread.
 */
object AudioDecoder {
    private const val TIMEOUT_US = 10_000L

    fun decodeToPcm16(path: String, out: String, maxSeconds: Int): Int {
        val maxUs = maxSeconds * 1_000_000L
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("no audio track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var floatPcm = false
            val c = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec = c
            c.configure(format, null, null, 0)
            c.start()
            val info = MediaCodec.BufferInfo()
            BufferedOutputStream(FileOutputStream(out), 1 shl 16).use { os ->
                var inputDone = false
                var outputDone = false
                var written = 0L
                while (!outputDone) {
                    if (!inputDone) {
                        val i = c.dequeueInputBuffer(TIMEOUT_US)
                        if (i >= 0) {
                            val n = extractor.readSampleData(c.getInputBuffer(i)!!, 0)
                            if (n < 0 || extractor.sampleTime > maxUs) {
                                c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                c.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val o = c.dequeueOutputBuffer(info, TIMEOUT_US)
                    if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val f = c.outputFormat
                        rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        floatPcm = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                            f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                    } else if (o >= 0) {
                        if (info.size > 0) {
                            val buf = c.getOutputBuffer(o)!!
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            val mono = downmix(buf.slice().order(ByteOrder.LITTLE_ENDIAN), channels, floatPcm)
                            val room = (rate.toLong() * maxSeconds * 2 - written).coerceAtLeast(0).toInt()
                            os.write(mono, 0, minOf(mono.size, room))
                            written += minOf(mono.size, room)
                        }
                        c.releaseOutputBuffer(o, false)
                        val full = written >= rate.toLong() * maxSeconds * 2
                        if (full || info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }
            return rate
        } finally {
            codec?.let {
                try {
                    it.stop()
                } catch (_: IllegalStateException) {
                }
                it.release()
            }
            extractor.release()
        }
    }

    /** Interleaved PCM (16-bit or float) to mono 16-bit little-endian bytes. */
    private fun downmix(buf: ByteBuffer, channels: Int, floatPcm: Boolean): ByteArray {
        val ch = channels.coerceAtLeast(1)
        val frames = buf.remaining() / ((if (floatPcm) 4 else 2) * ch)
        val out = ByteArray(frames * 2)
        val shorts = if (floatPcm) null else buf.asShortBuffer()
        val floats = if (floatPcm) buf.asFloatBuffer() else null
        for (f in 0 until frames) {
            var sum = 0.0
            for (k in 0 until ch) {
                sum += if (floats != null) floats.get(f * ch + k) * 32767.0 else shorts!!.get(f * ch + k).toDouble()
            }
            val v = (sum / ch).toInt().coerceIn(-32768, 32767)
            out[2 * f] = (v and 0xff).toByte()
            out[2 * f + 1] = ((v shr 8) and 0xff).toByte()
        }
        return out
    }
}
