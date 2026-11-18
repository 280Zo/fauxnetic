package dev.aj.fauxnetic

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.Process

/**
 * Runs the voice engine in its own process (":engine", see AndroidManifest.xml) so the app can stop
 * a line at once by killing this process; CrispASR has no way to stop a line partway (2026-11-16).
 * Requests arrive through a Messenger and run one at a time on [worker]; each reply carries the
 * request's id in arg1 and either "error"/"message" or the results.
 */
class EngineService : Service() {
    companion object {
        const val OP_OPEN = 1
        const val OP_VOICE = 2
        const val OP_SYNTH = 3
        const val OP_RATE = 4
        const val OP_CLOSE = 5
        const val OP_PID = 6
    }

    private val worker = HandlerThread("voice-engine")
    private lateinit var messenger: Messenger

    override fun onCreate() {
        super.onCreate()
        worker.start()
        messenger = Messenger(object : Handler(worker.looper) {
            override fun handleMessage(msg: Message) {
                val out = Bundle()
                handle(msg.what, msg.data, out)
                val reply = Message.obtain(null, msg.what, msg.arg1, 0)
                reply.data = out
                try {
                    msg.replyTo?.send(reply)
                } catch (_: Exception) {
                    // The app went away; nothing to tell.
                }
            }
        })
    }

    private fun refused(out: Bundle, code: String) {
        out.putString("error", code)
        out.putString("message", EngineNative.lastError())
    }

    private fun handle(op: Int, data: Bundle, out: Bundle) {
        when (op) {
            OP_OPEN -> if (!EngineNative.open(
                    data.getString("model", ""),
                    data.getString("codec", ""),
                    data.getString("backend", ""),
                    data.getInt("threads", 4),
                )
            ) refused(out, "open")
            OP_VOICE -> if (!EngineNative.setVoice(data.getString("path", ""), data.getString("refText", ""))) {
                refused(out, "voice")
            }
            OP_SYNTH -> {
                val path = data.getString("out", "")
                val n = EngineNative.synthesize(
                    data.getString("text", ""),
                    data.getLong("seed", 1),
                    path,
                    data.getInt("maxFrames", 0),
                )
                if (n == -2) {
                    refused(out, "ranaway")
                } else if (n < 0) {
                    refused(out, "synth")
                } else {
                    out.putString("path", path)
                    out.putInt("rate", EngineNative.sampleRate())
                }
            }
            OP_RATE -> out.putInt("rate", EngineNative.sampleRate())
            OP_CLOSE -> EngineNative.close()
            OP_PID -> out.putInt("pid", Process.myPid())
        }
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        worker.quitSafely()
        super.onDestroy()
    }
}
