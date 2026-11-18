// Host tests for the Qwen stall rule (app/android/app/src/main/cpp/stall.c).
// Run: cc -O2 -I app/android/app/src/main/cpp app/native/stall_test.c app/android/app/src/main/cpp/stall.c -o /tmp/opencode/stall_test && /tmp/opencode/stall_test
#include <stdio.h>

#include "stall.h"

static int failures;

#define CHECK(name, cond)                       \
    do {                                        \
        if (cond) {                             \
            printf("ok   %s\n", name);          \
        } else {                                \
            printf("FAIL %s\n", name);          \
            failures++;                         \
        }                                       \
    } while (0)

enum { QUIET = 164, SPEECH = 310, SPEECH2 = 749 };

// Feeds codes until the rule says stop; returns the frame it stopped on, or -1.
static int run(const int* codes, int n) {
    stall_state s;
    stall_init(&s);
    for (int f = 0; f < n; f++) {
        if (stall_feed(&s, codes[f])) return f;
    }
    return -1;
}

int main(void) {
    int codes[200];

    for (int f = 0; f < 200; f++) codes[f] = QUIET;
    CHECK("6 s of silence codes is a stall", run(codes, 200) == STALL_FRAMES - 1);

    for (int f = 17; f < 200; f++) codes[f] = f % 2 ? SPEECH : SPEECH2;
    CHECK("speech at 1.4 s is not a stall", run(codes, 200) == -1);

    for (int f = 0; f < 200; f++) codes[f] = QUIET;
    for (int f = 70; f < 200; f++) codes[f] = SPEECH;
    CHECK("speech at 5.6 s is not a stall", run(codes, 200) == -1);

    for (int f = 0; f < 200; f++) codes[f] = QUIET;
    codes[10] = codes[11] = SPEECH;
    codes[40] = SPEECH;
    CHECK("a stray code or two in silence is still a stall", run(codes, 200) == STALL_FRAMES - 1);

    for (int f = 0; f < 200; f++) codes[f] = QUIET;
    CHECK("a line that ends before 6 s is never a stall", run(codes, 40) == -1);

    for (int f = 0; f < 200; f++) codes[f] = f < 20 ? SPEECH : QUIET;
    CHECK("silence after speech is not a stall", run(codes, 200) == -1);

    for (int f = 0; f < 200; f++) codes[f] = 2047;
    CHECK("codes the list doesn't know count as speech", run(codes, 200) == -1);

    // Review 2026-11-17: a line that failed before any frame was made (e.g. no voice) must not be
    // reported as a runaway because of the previous line's stop reason.
    stall_state s;
    stall_init(&s);
    CHECK("a failure before any frame is not a runaway", ranaway_reason(2, &s) == 0);
    stall_feed(&s, SPEECH);
    CHECK("a frame limit after frames is a runaway", ranaway_reason(2, &s) == 2);
    CHECK("an end of speech is not a runaway", ranaway_reason(1, &s) == 0);
    CHECK("a stop by the watch is a runaway", ranaway_reason(4, &s) == 4);

    printf(failures ? "%d failed\n" : "all passed\n", failures);
    return failures != 0;
}
