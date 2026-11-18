// Stall rule for Qwen3-TTS lines, fed one codebook-0 code per generated frame (12.5 a second).
// A line that never ends opens with long silence (7.8-16 s measured on the A54, 2026-11-16/17);
// lines that finish start speaking within ~5 s. So: no speech within 6 s means stop and retry.
#ifndef FAUXNETIC_STALL_H
#define FAUXNETIC_STALL_H

#include <stdint.h>

// 6 s of audio. Healthy lines started speaking by 4.8 s at the latest.
#define STALL_FRAMES 75
// Frames in a row that must be speech codes before the line counts as speaking.
#define STALL_SPEECH_RUN 3

typedef struct {
    int frames;
    int run;
    int heard;
} stall_state;

void stall_init(stall_state* s);

// Returns 1 when the line should be stopped now.
int stall_feed(stall_state* s, int32_t cb0);

// The stop reason (2 frame limit, 3 KV ceiling, 4 stopped by the watch) when the line just made
// went wrong and should be made again, else 0. A line that made no frame failed for another reason
// (CrispASR keeps the previous line's stop reason then), so it is never a runaway.
int ranaway_reason(int stop_reason, const stall_state* s);

#endif
