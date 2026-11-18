package dev.aj.fauxnetic

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val decodeThread = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    companion object {
        /** One engine connection for the app process, kept across activity restarts. */
        private var engine: EngineClient? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Opens this app's own settings page, so a denied microphone can be allowed again.
        MethodChannel(messenger, "fauxnetic/settings").setMethodCallHandler { call, result ->
            when (call.method) {
                "openAppSettings" -> {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(null)
                }
                // A report draft in the user's email app (mailto: so only email apps answer);
                // nothing is sent until they send it. False when there is no email app.
                "emailReport" -> {
                    val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:")).apply {
                        putExtra(Intent.EXTRA_EMAIL, arrayOf(call.argument<String>("to") ?: ""))
                        putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "")
                        putExtra(Intent.EXTRA_TEXT, call.argument<String>("body") ?: "")
                    }
                    try {
                        startActivity(intent)
                        result.success(true)
                    } catch (_: android.content.ActivityNotFoundException) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // The voice engine, in its own process (see EngineService and EngineClient).
        val client = engine ?: EngineClient(applicationContext).also { engine = it }
        var nextLine = 0
        MethodChannel(messenger, "fauxnetic/engine").setMethodCallHandler { call, result ->
            fun send(op: Int, data: Bundle, onOk: (Bundle) -> Any?) =
                client.send(op, data) { error, message, out ->
                    if (error == null) result.success(onOk(out)) else result.error(error, message, null)
                }
            when (call.method) {
                "open" -> send(EngineService.OP_OPEN, Bundle().apply {
                    putString("model", call.argument<String>("model"))
                    putString("codec", call.argument<String>("codec") ?: "")
                    putString("backend", call.argument<String>("backend"))
                    putInt("threads", call.argument<Int>("threads") ?: 4)
                }) { null }
                "setVoice" -> send(EngineService.OP_VOICE, Bundle().apply {
                    putString("path", call.argument<String>("path"))
                    putString("refText", call.argument<String>("refText") ?: "")
                }) { null }
                "synthesize" -> {
                    // vault-tmp: the folder TempSweeper empties on every launch, so a line left
                    // behind by a kill mid-write doesn't outlive the app's cleanup.
                    val dir = File(cacheDir, "vault-tmp").apply { mkdirs() }
                    val out = File(dir, "line-${nextLine++}.f32").path
                    send(EngineService.OP_SYNTH, Bundle().apply {
                        putString("text", call.argument<String>("text"))
                        putLong("seed", (call.argument<Number>("seed") ?: 1).toLong())
                        putInt("maxFrames", call.argument<Int>("maxFrames") ?: 0)
                        putString("out", out)
                    }) { mapOf("path" to it.getString("path"), "rate" to it.getInt("rate")) }
                }
                "sampleRate" -> send(EngineService.OP_RATE, Bundle()) { it.getInt("rate") }
                "close" -> send(EngineService.OP_CLOSE, Bundle()) { null }
                "kill" -> {
                    client.kill()
                    result.success(null)
                }
                "pid" -> result.success(client.pid)
                else -> result.notImplemented()
            }
        }
        // Decodes uploaded audio and video off the UI thread (see AudioDecoder).
        MethodChannel(messenger, "fauxnetic/decode").setMethodCallHandler { call, result ->
            if (call.method != "decodeToPcm16") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val out = call.argument<String>("out")
            val maxSeconds = call.argument<Int>("maxSeconds") ?: 300
            if (path == null || out == null) {
                result.error("decode", "path and out are required", null)
                return@setMethodCallHandler
            }
            decodeThread.execute {
                try {
                    val rate = AudioDecoder.decodeToPcm16(path, out, maxSeconds)
                    main.post { result.success(rate) }
                } catch (e: Exception) {
                    main.post { result.error("decode", e.message ?: e.javaClass.simpleName, null) }
                }
            }
        }
    }

    override fun onDestroy() {
        decodeThread.shutdown()
        super.onDestroy()
    }
}
