// JNI bridge for EngineService (process ":engine"): makes lines through CrispASR's session C API,
// the same calls in the same order as FfiCrispasrApi on the Dart side. libcrispasr.so is loaded
// with dlopen (it sits in the APK's library folder), so nothing here links against it.
#include <dlfcn.h>
#include <jni.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "stall.h"

typedef void* (*open_fn)(const char*, const char*, int);
typedef int (*frame_watch_cb)(int, int32_t, void*);
typedef int (*watch_fn)(void*, frame_watch_cb, void*);
typedef int (*stop_reason_fn)(void*);
typedef int (*lang_fn)(void*, const char*);
typedef int (*codec_fn)(void*, const char*);
typedef int (*voice_fn)(void*, const char*, const char*);
typedef int (*seed_fn)(void*, uint64_t);
typedef float* (*synth_fn)(void*, const char*, int*);
typedef void (*pcm_free_fn)(float*);
typedef int (*rate_fn)(void*);
typedef void (*close_fn)(void*);
typedef const char* (*err_fn)(void*);

static void* lib;
static open_fn p_open;
static codec_fn p_codec;
static voice_fn p_voice;
static seed_fn p_seed;  // optional, as in the Dart binding
static synth_fn p_synth;
static pcm_free_fn p_pcm_free;
static rate_fn p_rate;
static close_fn p_close;
static err_fn p_synth_error;  // optional
// Fauxnetic's CrispASR patch (app/native/patches); optional so an unpatched library still works.
static watch_fn p_watch;
static stop_reason_fn p_stop_reason;
static lang_fn p_target_lang;

static void* session;
static int qwen;  // the open session is Qwen3-TTS
static stall_state stall;

static int on_frame(int frame, int32_t cb0, void* ud) {
    (void)frame;
    (void)ud;
    return stall_feed(&stall, cb0);
}
static char last_error[512];

static void set_error(const char* what, const char* detail) {
    snprintf(last_error, sizeof last_error, "%s%s%s", what, detail && *detail ? ": " : "", detail ? detail : "");
}

static int load(void) {
    if (lib) return 1;
    void* h = dlopen("libcrispasr.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        set_error("could not load libcrispasr.so", dlerror());
        return 0;
    }
    p_open = (open_fn)dlsym(h, "crispasr_session_open_explicit");
    p_codec = (codec_fn)dlsym(h, "crispasr_session_set_codec_path");
    p_voice = (voice_fn)dlsym(h, "crispasr_session_set_voice");
    p_seed = (seed_fn)dlsym(h, "crispasr_session_set_tts_seed");
    p_synth = (synth_fn)dlsym(h, "crispasr_session_synthesize");
    p_pcm_free = (pcm_free_fn)dlsym(h, "crispasr_pcm_free");
    p_rate = (rate_fn)dlsym(h, "crispasr_session_output_sample_rate");
    p_close = (close_fn)dlsym(h, "crispasr_session_close");
    p_synth_error = (err_fn)dlsym(h, "crispasr_session_last_synth_error");
    p_watch = (watch_fn)dlsym(h, "crispasr_session_set_tts_frame_watch");
    p_stop_reason = (stop_reason_fn)dlsym(h, "crispasr_session_last_tts_stop_reason");
    p_target_lang = (lang_fn)dlsym(h, "crispasr_session_set_target_language");
    if (!p_open || !p_codec || !p_voice || !p_synth || !p_pcm_free || !p_rate || !p_close) {
        set_error("libcrispasr.so is missing a session function", NULL);
        dlclose(h);
        return 0;
    }
    lib = h;
    return 1;
}

static void close_session(void) {
    if (session) {
        p_close(session);
        session = NULL;
    }
}

#define JNI_FN(name) Java_dev_aj_fauxnetic_EngineNative_##name

JNIEXPORT jboolean JNICALL JNI_FN(open)(JNIEnv* env, jobject self, jstring model, jstring codec, jstring backend,
                                        jint threads) {
    (void)self;
    if (!load()) return JNI_FALSE;
    // The phone can't hold two models: free the old session first.
    close_session();
    const char* m = (*env)->GetStringUTFChars(env, model, NULL);
    const char* c = (*env)->GetStringUTFChars(env, codec, NULL);
    const char* b = (*env)->GetStringUTFChars(env, backend, NULL);
    session = p_open(m, b, threads);
    jboolean ok = JNI_TRUE;
    if (!session) {
        set_error("could not open the voice model", m);
        ok = JNI_FALSE;
    } else if (*c && p_codec(session, c) != 0) {
        // Single-file models have no codec; the others must load theirs.
        set_error("could not open the codec", c);
        close_session();
        ok = JNI_FALSE;
    }
    qwen = ok && strcmp(b, "qwen3-tts") == 0;
    if (qwen) {
        // Qwen's own examples set the language when it's known; Fauxnetic is English only.
        if (p_target_lang) p_target_lang(session, "en");
        if (p_watch) p_watch(session, on_frame, NULL);
    }
    (*env)->ReleaseStringUTFChars(env, model, m);
    (*env)->ReleaseStringUTFChars(env, codec, c);
    (*env)->ReleaseStringUTFChars(env, backend, b);
    return ok;
}

JNIEXPORT jboolean JNICALL JNI_FN(setVoice)(JNIEnv* env, jobject self, jstring path, jstring refText) {
    (void)self;
    if (!session) {
        set_error("engine not open", NULL);
        return JNI_FALSE;
    }
    const char* p = (*env)->GetStringUTFChars(env, path, NULL);
    const char* r = (*env)->GetStringUTFChars(env, refText, NULL);
    int rc = p_voice(session, p, r);
    (*env)->ReleaseStringUTFChars(env, path, p);
    (*env)->ReleaseStringUTFChars(env, refText, r);
    if (rc != 0) {
        char rcs[32];
        snprintf(rcs, sizeof rcs, "rc=%d", rc);
        set_error("setVoice failed", rcs);
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

// Writes the samples to outPath as Float32 little-endian; returns the count, -1 on failure, or -2
// when a Qwen line went wrong (silent too long, or ran to its limit) and should be made again.
// maxFrames > 0 caps a Qwen line's length (CrispASR reads CRISPASR_QWEN3_TTS_MAX_FRAMES on every
// line); 0 leaves its default.
JNIEXPORT jint JNICALL JNI_FN(synthesize)(JNIEnv* env, jobject self, jstring text, jlong seed, jstring outPath,
                                          jint maxFrames) {
    (void)self;
    if (!session) {
        set_error("engine not open", NULL);
        return -1;
    }
    if (maxFrames > 0) {
        char v[16];
        snprintf(v, sizeof v, "%d", (int)maxFrames);
        setenv("CRISPASR_QWEN3_TTS_MAX_FRAMES", v, 1);
    } else {
        unsetenv("CRISPASR_QWEN3_TTS_MAX_FRAMES");
    }
    // qwen3-tts reads the seed from set_tts_seed, not the temperature call.
    if (p_seed) p_seed(session, (uint64_t)seed);
    const char* t = (*env)->GetStringUTFChars(env, text, NULL);
    int n = 0;
    stall_init(&stall);
    float* pcm = p_synth(session, t, &n);
    (*env)->ReleaseStringUTFChars(env, text, t);
    const int reason = qwen && p_stop_reason ? ranaway_reason(p_stop_reason(session), &stall) : 0;
    if (reason) {
        set_error(reason == 4 ? "ranaway: stall" : "ranaway: limit", NULL);
        if (pcm) p_pcm_free(pcm);
        return -2;
    }
    if (!pcm || n <= 0) {
        const char* why = p_synth_error ? p_synth_error(session) : NULL;
        set_error("synthesize failed", why);
        if (pcm) p_pcm_free(pcm);
        return -1;
    }
    const char* o = (*env)->GetStringUTFChars(env, outPath, NULL);
    FILE* f = fopen(o, "wb");
    (*env)->ReleaseStringUTFChars(env, outPath, o);
    size_t wrote = f ? fwrite(pcm, sizeof(float), (size_t)n, f) : 0;
    int closed = f ? fclose(f) : EOF;
    p_pcm_free(pcm);
    if (wrote != (size_t)n || closed != 0) {
        set_error("could not write the line", NULL);
        return -1;
    }
    return n;
}

JNIEXPORT jint JNICALL JNI_FN(sampleRate)(JNIEnv* env, jobject self) {
    (void)env;
    (void)self;
    return session ? p_rate(session) : 0;
}

JNIEXPORT void JNICALL JNI_FN(close)(JNIEnv* env, jobject self) {
    (void)env;
    (void)self;
    if (lib) close_session();
}

JNIEXPORT jstring JNICALL JNI_FN(lastError)(JNIEnv* env, jobject self) {
    (void)self;
    return (*env)->NewStringUTF(env, last_error);
}
