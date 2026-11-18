// C ABI smoke test for libcrispasr on the phone: clone a voice and synthesize one line.
// Usage: abi_smoke <talker.gguf> <codec.gguf> <voice.wav|m4a> <ref_text> <text> <out.wav>
// Exit 0 and "samples=<n> rate=<hz>" on success; non-zero with CrispASR's error otherwise.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "crispasr.h"
#include "crispasr_session.h"

static int write_wav(const char* path, const float* pcm, int n, int rate) {
    FILE* f = fopen(path, "wb");
    if (!f) return -1;
    uint32_t data = (uint32_t)n * 2u, riff = 36u + data, fmt_len = 16u, byte_rate = (uint32_t)rate * 2u;
    uint16_t pcm_fmt = 1, ch = 1, align = 2, bits = 16;
    uint32_t sr = (uint32_t)rate;
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmt_len, 4, 1, f); fwrite(&pcm_fmt, 2, 1, f); fwrite(&ch, 2, 1, f);
    fwrite(&sr, 4, 1, f); fwrite(&byte_rate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
    for (int i = 0; i < n; i++) {
        float v = pcm[i] > 1.f ? 1.f : (pcm[i] < -1.f ? -1.f : pcm[i]);
        int16_t s = (int16_t)(v * 32767.f);
        fwrite(&s, 2, 1, f);
    }
    return fclose(f);
}

int main(int argc, char** argv) {
    if (argc != 7) {
        fprintf(stderr, "usage: %s talker.gguf codec.gguf voice ref_text text out.wav\n", argv[0]);
        return 2;
    }
    crispasr_session* s = crispasr_session_open_explicit(argv[1], "qwen3-tts", 4);
    if (!s) { fprintf(stderr, "open failed\n"); return 3; }
    if (crispasr_session_set_codec_path(s, argv[2]) != 0) {
        fprintf(stderr, "set_codec_path failed\n"); crispasr_session_close(s); return 4;
    }
    if (crispasr_session_set_voice(s, argv[3], argv[4]) != 0) {
        const char* e = crispasr_session_last_synth_error(s);
        fprintf(stderr, "set_voice failed: %s\n", e ? e : "(no detail)");
        crispasr_session_close(s); return 5;
    }
    int n = 0;
    float* pcm = crispasr_session_synthesize(s, argv[5], &n);
    if (!pcm || n <= 0) {
        const char* e = crispasr_session_last_synth_error(s);
        fprintf(stderr, "synthesize failed: %s\n", e ? e : "(no detail)");
        crispasr_session_close(s); return 6;
    }
    int rate = crispasr_session_output_sample_rate(s);
    int rc = write_wav(argv[6], pcm, n, rate > 0 ? rate : 24000);
    crispasr_pcm_free(pcm);
    crispasr_session_close(s);
    if (rc != 0) { fprintf(stderr, "write failed\n"); return 7; }
    printf("samples=%d rate=%d\n", n, rate);
    return 0;
}
