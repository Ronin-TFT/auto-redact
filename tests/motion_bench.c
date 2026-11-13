// ARMotion 性能：1920×1080 画面，20 处打码内容持续滚动，统计每帧耗时。
// 构建：cc -O2 -I mac tests/motion_bench.c mac/ARMotion.c -lm -o build/motion-bench && build/motion-bench
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "ARMotion.h"

enum { BW = 1920, BH = 1080, N = 20 };

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(void) {
    uint8_t *frame = malloc((size_t)BW * BH * 4);
    ARMotionSession *m = ARMotionCreate(BW, BH, 2, 6, 0.6);
    ARBox boxes[N];
    uint32_t keys[N];
    double addTotal = 0, detectTotal = 0;
    int frames = 120;
    for (int f = 0; f < frames; f++) {
        double offset = f * 20.0;
        for (int i = 0; i < BW * BH; i++) {
            int y = i / BW, x = i % BW;
            int row = (int)((y + offset) / 3), col = x / 3;
            uint8_t v = ((row * 7919 + col * 104729) % 97 < 30 && ((y + (int)offset) % 54) < 30) ? 30 : 235;
            frame[i * 4] = frame[i * 4 + 1] = frame[i * 4 + 2] = v;
            frame[i * 4 + 3] = 255;
        }
        double t0 = now();
        long id = ARMotionAddFrame(m, frame, BW * 4, f / 60.0);
        addTotal += now() - t0;
        if (f % 6 == 0) {
            for (int i = 0; i < N; i++) {
                ARBox b = {200 + (i % 2) * 800, 40 + i * 50.0, 360, 30};
                boxes[i] = b;
                keys[i] = (uint32_t)(i + 1 + f * 100);
            }
            t0 = now();
            ARMotionAddDetections(m, id, boxes, keys, N);
            detectTotal += now() - t0;
        }
        ARMotionRelease(m, id - 30);
    }
    printf("1920x1080, %d boxes: AddFrame %.2f ms/frame, AddDetections %.2f ms each\n",
           N, addTotal / frames * 1000, detectTotal / (frames / 6) * 1000);
    ARMotionDestroy(m);
    free(frame);
    return 0;
}
