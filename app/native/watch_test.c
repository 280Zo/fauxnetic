// Test for Fauxnetic's CrispASR patch (app/native/patches): with a frame watch set, a Qwen line that is
// stopped (by the watch, or at its frame limit) comes back empty without being decoded, and a line
// that ends normally still comes back as audio.
// Usage: watch_test talker codec voice.wav ref_text   (CRISPASR_QWEN3_TTS_MAX_FRAMES set per case here)
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include "qwen3_tts.h"

static int frames_seen;

static int count(int frame, int32_t cb0, void* ud) {
    (void)cb0;
    (void)ud;
    frames_seen = frame + 1;
    return 0;
}

static int stop_at_10(int frame, int32_t cb0, void* ud) {
    (void)cb0;
    (void)ud;
    return frame >= 9;
}

static int failures;

static void check(const char* name, int ok) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    failures += !ok;
}

int main(int argc, char** argv) {
    if (argc != 5) return 2;
    struct qwen3_tts_context_params p = qwen3_tts_context_default_params();
    p.n_threads = 4;
    p.verbosity = 0;
    struct qwen3_tts_context* ctx = qwen3_tts_init_from_file(argv[1], p);
    if (!ctx || qwen3_tts_set_codec_path(ctx, argv[2]) != 0) return 3;
    if (qwen3_tts_set_voice_prompt_with_text(ctx, argv[3], argv[4]) != 0) return 4;
    const char* line = "The package should arrive on Thursday.";
    int n = 0;

    qwen3_tts_set_seed(ctx, 1);
    qwen3_tts_set_frame_watch(ctx, count, NULL);
    float* pcm = qwen3_tts_synthesize(ctx, line, &n);
    check("a line that ends normally comes back as audio", pcm && n > 0 && qwen3_tts_last_stop_reason(ctx) == 1);
    qwen3_tts_pcm_free(pcm);

    qwen3_tts_set_frame_watch(ctx, stop_at_10, NULL);
    pcm = qwen3_tts_synthesize(ctx, line, &n);
    check("a line the watch stops comes back empty", !pcm && qwen3_tts_last_stop_reason(ctx) == 4);
    qwen3_tts_pcm_free(pcm);

    setenv("CRISPASR_QWEN3_TTS_MAX_FRAMES", "12", 1);
    qwen3_tts_set_frame_watch(ctx, count, NULL);
    pcm = qwen3_tts_synthesize(ctx, line, &n);
    check("a watched line stopped at its frame limit comes back empty", !pcm && qwen3_tts_last_stop_reason(ctx) == 2);
    qwen3_tts_pcm_free(pcm);

    qwen3_tts_set_frame_watch(ctx, NULL, NULL);
    pcm = qwen3_tts_synthesize(ctx, line, &n);
    check("without a watch, a line at its limit still comes back (CrispASR's own behavior)", pcm && n > 0);
    qwen3_tts_pcm_free(pcm);
    unsetenv("CRISPASR_QWEN3_TTS_MAX_FRAMES");

    qwen3_tts_free(ctx);
    printf(failures ? "%d failed\n" : "all passed\n", failures);
    return failures != 0;
}
