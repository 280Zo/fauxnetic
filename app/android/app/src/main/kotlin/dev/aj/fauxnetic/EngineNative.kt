package dev.aj.fauxnetic

/** CrispASR's session calls, through engine_bridge.c. Only used in the ":engine" process. */
object EngineNative {
    init {
        System.loadLibrary("voiceengine")
    }

    external fun open(model: String, codec: String, backend: String, threads: Int): Boolean

    external fun setVoice(path: String, refText: String): Boolean

    /**
     * Writes the samples to [outPath] as Float32 little-endian; returns how many, or -1. [maxFrames]
     * > 0 caps a Qwen line's length.
     */
    external fun synthesize(text: String, seed: Long, outPath: String, maxFrames: Int): Int

    external fun sampleRate(): Int

    external fun close()

    external fun lastError(): String
}
