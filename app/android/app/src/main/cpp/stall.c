#include "stall.h"

// Codebook-0 codes Qwen3-TTS 0.6B uses for silence: codes heard more often below -45 dBFS than
// above it, across 8 lines (A54, 2026-11-17). A code not listed counts as speech, so an unknown
// voice can only make the rule miss a stall, never stop a good line.
static const int16_t kQuiet[] = {
    3,    6,    25,   84,   125,  142,  162,  164,  178,  183,  186,  190,  207,  224,  234,  254,
    257,  268,  284,  292,  309,  336,  350,  362,  365,  366,  385,  444,  465,  485,  491,  592,
    617,  654,  664,  668,  674,  688,  699,  706,  711,  814,  831,  847,  856,  869,  886,  892,
    909,  937,  960,  1025, 1047, 1080, 1093, 1100, 1110, 1128, 1154, 1254, 1263, 1281, 1289, 1297,
    1318, 1354, 1368, 1383, 1449, 1501, 1511, 1523, 1524, 1531, 1553, 1554, 1571, 1582, 1592, 1657,
    1733, 1734, 1775, 1797, 1848, 1851, 1859, 1894, 1898, 1915, 1938, 1984, 2022, 2037,
};

static int quiet(int32_t code) {
    int lo = 0, hi = (int)(sizeof kQuiet / sizeof kQuiet[0]) - 1;
    while (lo <= hi) {
        const int mid = (lo + hi) / 2;
        if (kQuiet[mid] == code) return 1;
        if (kQuiet[mid] < code) lo = mid + 1;
        else hi = mid - 1;
    }
    return 0;
}

void stall_init(stall_state* s) {
    s->frames = 0;
    s->run = 0;
    s->heard = 0;
}

int ranaway_reason(int stop_reason, const stall_state* s) {
    if (s->frames == 0) return 0;
    return stop_reason == 2 || stop_reason == 3 || stop_reason == 4 ? stop_reason : 0;
}

int stall_feed(stall_state* s, int32_t cb0) {
    s->frames++;
    if (s->heard) return 0;
    s->run = quiet(cb0) ? 0 : s->run + 1;
    if (s->run >= STALL_SPEECH_RUN) {
        s->heard = 1;
        return 0;
    }
    return s->frames >= STALL_FRAMES;
}
