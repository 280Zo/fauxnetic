package dev.aj.fauxnetic

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import java.io.File

/**
 * The app's side of [EngineService]. Binds it when a request comes in (a fresh process after a kill
 * or a crash), sends requests with an id and hands each reply to its callback. Everything here runs
 * on the main thread.
 *
 * [kill] ends the engine process at once: requests waiting on it fail with "cancelled". If the
 * process dies on its own (for example out of memory), they fail with "died".
 */
class EngineClient(private val context: Context) {
    /** A reply: null error means success, with the results in the bundle. */
    fun interface Reply {
        fun done(error: String?, message: String?, data: Bundle)
    }

    private val main = Handler(Looper.getMainLooper())
    private val replies = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(msg: Message) {
            val r = pending.remove(msg.arg1) ?: return
            val data = msg.data
            if (msg.what == EngineService.OP_PID) pid = data.getInt("pid")
            r.done(data.getString("error"), data.getString("message"), data)
        }
    })

    private val pending = LinkedHashMap<Int, Reply>()
    private val waiting = ArrayList<Message>()
    private var nextId = 1
    private var service: Messenger? = null
    private var bound = false

    /** The engine process's pid, once known; null when there's none. */
    var pid: Int? = null
        private set

    /**
     * A process [kill] ended that may still be shutting down. Binding before it is gone attached the
     * new request to the dying process, and Android then never started a fresh engine: the loading
     * screen waited forever (A54, 2026-11-17). So binding waits for it to go.
     */
    private var dyingPid: Int? = null
    private var bindQueued = false

    private val connectTimeout: Runnable = Runnable {
        if (service == null && bound) {
            context.unbindService(connection)
            bound = false
            failAll("nostart", "The voice engine didn't start. Try again.")
        }
    }

    private val connection: ServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            main.removeCallbacks(connectTimeout)
            val s = Messenger(binder)
            service = s
            // Ask for the pid first, so a kill can reach this process.
            send(EngineService.OP_PID, Bundle()) { _, _, _ -> }
            for (m in waiting) s.send(m)
            waiting.clear()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // The process died without being asked to (a kill unbinds first).
            service = null
            pid = null
            failAll("died", "The voice engine stopped unexpectedly.")
        }
    }

    private fun failAll(code: String, message: String) {
        val all = pending.values.toList()
        pending.clear()
        waiting.clear()
        for (r in all) main.post { r.done(code, message, Bundle()) }
    }

    fun send(op: Int, data: Bundle, reply: Reply) {
        val id = nextId++
        pending[id] = reply
        val msg = Message.obtain(null, op, id, 0)
        msg.data = data
        msg.replyTo = replies
        val s = service
        if (s != null) {
            try {
                s.send(msg)
            } catch (_: Exception) {
                pending.remove(id)
                main.post { reply.done("died", "The voice engine stopped unexpectedly.", Bundle()) }
            }
            return
        }
        waiting.add(msg)
        bindWhenReady()
    }

    /** Binds the engine once the process a [kill] ended is gone (checked every 50 ms, up to 3 s). */
    private fun bindWhenReady(waitedMs: Int = 0) {
        if (bound || (bindQueued && waitedMs == 0)) return
        val dying = dyingPid
        if (dying != null && File("/proc/$dying").exists() && waitedMs < 3000) {
            bindQueued = true
            main.postDelayed({ bindWhenReady(waitedMs + 50) }, 50)
            return
        }
        bindQueued = false
        dyingPid = null
        if (waiting.isEmpty()) return
        bound = context.bindService(
            Intent(context, EngineService::class.java),
            connection,
            Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT,
        )
        if (!bound) {
            failAll("died", "The voice engine could not start.")
            return
        }
        main.postDelayed(connectTimeout, 20000)
    }

    /** The engine process by name, for a kill that comes before it reported its pid. */
    private fun findEnginePid(): Int? {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val name = "${context.packageName}:engine"
        return am.runningAppProcesses?.firstOrNull { it.processName == name }?.pid
    }

    /** Ends the engine process now; waiting requests fail with "cancelled". */
    fun kill() {
        val p = pid ?: findEnginePid()
        if (bound) {
            context.unbindService(connection)
            bound = false
        }
        main.removeCallbacks(connectTimeout)
        service = null
        pid = null
        failAll("cancelled", "Stopped.")
        if (p != null && p != Process.myPid()) {
            Process.killProcess(p)
            dyingPid = p
        }
    }
}
