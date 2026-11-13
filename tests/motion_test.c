// ARMotion 的测试：程序生成类似文字的滚动画面，模拟“每隔几帧识别一次、识别有延迟”，
// 逐帧检查每一处敏感信息都被遮住，并检查遮挡框没有过大。
// 构建：cc -O2 -I mac tests/motion_test.c mac/ARMotion.c -lm -o build/motion-test && build/motion-test
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ARMotion.h"

enum { W = 960, H = 540, MAXI = 64 };

typedef struct {
    double x, y, w, h;
    uint32_t seed;
    int sensitive, scrolls;
} Item;

static uint32_t mix(uint32_t a, uint32_t b, uint32_t c) {
    uint32_t h = a * 2654435761u ^ b * 2246822519u ^ c * 3266489917u;
    h ^= h >> 15; h *= 2246822519u; h ^= h >> 13;
    return h;
}

/// 画一帧：浅色背景上的“文字”（3×3 像素一笔的随机笔画，每项图案不同）。
static void render(uint8_t *bgra, const Item *items, int n) {
    for (int i = 0; i < W * H; i++) { bgra[i * 4] = bgra[i * 4 + 1] = bgra[i * 4 + 2] = 235; bgra[i * 4 + 3] = 255; }
    for (int k = 0; k < n; k++) {
        const Item *it = &items[k];
        int x0 = (int)floor(it->x), y0 = (int)floor(it->y);
        for (int y = y0; y < y0 + (int)it->h; y++) {
            if (y < 0 || y >= H) continue;
            for (int x = x0; x < x0 + (int)it->w; x++) {
                if (x < 0 || x >= W) continue;
                int lx = (x - x0) / 3, ly = (y - y0) / 3;
                if (mix(it->seed, (uint32_t)lx, (uint32_t)ly) % 100 < 38) {
                    uint8_t *p = bgra + ((size_t)y * W + x) * 4;
                    p[0] = p[1] = p[2] = 30;
                }
            }
        }
    }
}

static int clipItem(const Item *it, ARBox *out) {
    double x0 = fmax(0, it->x), y0 = fmax(0, it->y), x1 = fmin(W, it->x + it->w), y1 = fmin(H, it->y + it->h);
    if (x1 <= x0 || y1 <= y0) return 0;
    out->x = x0; out->y = y0; out->w = x1 - x0; out->h = y1 - y0;
    return 1;
}

static int pointCovered(const ARBox *boxes, int n, double x, double y) {
    for (int i = 0; i < n; i++)
        if (x >= boxes[i].x && x <= boxes[i].x + boxes[i].w && y >= boxes[i].y && y <= boxes[i].y + boxes[i].h) return 1;
    return 0;
}

/// 检查一项的可见部分被完全覆盖（取 7×5 个采样点）。
static int itemCovered(const ARBox *boxes, int n, const Item *it) {
    ARBox c;
    if (!clipItem(it, &c)) return 1;
    for (int i = 0; i <= 6; i++)
        for (int j = 0; j <= 4; j++)
            if (!pointCovered(boxes, n, c.x + c.w * i / 6.0, c.y + c.h * j / 4.0)) return 0;
    return 1;
}

typedef struct {
    int items;
    Item list[MAXI];
} Scene;

/// 一列可滚动的内容：敏感项与普通文字行交替，另有一处不滚动的敏感项。
static Scene makeScene(void) {
    Scene s = {0};
    for (int i = 0; i < 40; i++) {
        Item it = {120, 40 + i * 36.0, i % 3 == 0 ? 260 : 420, 22, 1000u + (uint32_t)i, i % 3 == 0, 1};
        s.list[s.items++] = it;
    }
    Item fixed = {700, 60, 180, 22, 77, 1, 0};
    s.list[s.items++] = fixed;
    return s;
}

static void advance(Scene *s, double dy) {
    for (int i = 0; i < s->items; i++)
        if (s->list[i].scrolls) s->list[i].y -= dy;
}

/// 识别结果：完全可见的敏感项（识别不到被截断的文字）。
static int detect(const Scene *s, ARBox *boxes, uint32_t *keys) {
    int n = 0;
    for (int i = 0; i < s->items; i++) {
        const Item *it = &s->list[i];
        if (!it->sensitive || it->y < 0 || it->y + it->h > H || it->x < 0 || it->x + it->w > W) continue;
        ARBox b = {it->x, it->y, it->w, it->h};
        boxes[n] = b;
        keys[n] = it->seed;
        n++;
    }
    return n;
}

typedef struct {
    int frames, period, latency, skipRound;
    double (*speed)(int frame);
    int checkPrediction;
    int missPercent; // 每一处内容每次识别被漏掉的概率（%），模拟小字、浅色字时有时无
} Scenario;

typedef struct {
    int uncovered;      // 本来能识别到、却没遮住（缺陷）
    int unrecognizable; // 从未完整出现在任何一次识别中（文字识别的极限）
    double areaRatio;
    int predictionMisses;
} Result;

/// 已送达的识别所对应的帧，以及每次识别到了哪些内容。
static long detectionFrames[512];
static uint32_t detectionKeys[512][MAXI];
static int detectionCounts[512];
static int ndetections;

static int onScreen(const Item *it) { return it->y + it->h > 0 && it->y < H && it->x + it->w > 0 && it->x < W; }

/// 某一项在第 f 帧是否“能被识别”：存在一次已送达的识别，那一帧它完整可见，
/// 且从那一帧到第 f 帧它一直在画面内（可以连续追踪过来）。
static int recognizable(const Scene *history, long f, int item) {
    for (int d = 0; d < ndetections; d++) {
        long k = detectionFrames[d];
        int seenHere = 0;
        for (int i = 0; i < detectionCounts[d]; i++) seenHere |= detectionKeys[d][i] == history[k].list[item].seed;
        if (!seenHere) continue;
        long a = k < f ? k : f, b = k < f ? f : k;
        int continuous = 1;
        for (long j = a; j <= b && continuous; j++) continuous = onScreen(&history[j].list[item]);
        if (continuous) return 1;
    }
    return 0;
}

typedef struct {
    double ratioSum;
    int ratioN;
} Stats;

/// 和 App 一样：帧一写入就用当时的结果检查。
static void writeFrame(ARMotionSession *m, long f, const Scene *history, Result *r, Stats *st) {
    const Scene *truth = &history[f];
    ARBox out[MAXI];
    int n = ARMotionBoxesForFrame(m, f, out, MAXI);
    double area = 0, expected = 0;
    for (int i = 0; i < truth->items; i++) {
        const Item *it = &truth->list[i];
        if (!it->sensitive) continue;
        ARBox c;
        if (clipItem(it, &c)) expected += (c.w + 8) * (c.h + 8);
        if (!itemCovered(out, n, it)) {
            if (!recognizable(history, f, i)) {
                r->unrecognizable++;
                continue;
            }
            if (r->uncovered < 4) fprintf(stderr, "    frame %ld item %u at y=%.1f not covered\n", f, it->seed, it->y);
            r->uncovered++;
        }
    }
    for (int i = 0; i < n; i++) area += out[i].w * out[i].h;
    if (expected > 0) { st->ratioSum += area / expected; st->ratioN++; }
}

static Result run(const Scenario *sc) {
    ARMotionSession *m = ARMotionCreate(W, H, 2, 4, 0.6);
    Scene scene = makeScene();
    uint8_t *frame = malloc((size_t)W * H * 4);
    Scene *history = malloc(sizeof(Scene) * (size_t)sc->frames);
    ARBox pendingBoxes[MAXI];
    uint32_t pendingKeys[MAXI];
    int pendingCount = 0;
    long pendingFrame = -1;
    int deliverAt = -1, round = 0;
    uint32_t seen[MAXI];
    int nseen = 0;
    Result r = {0, 0, 0, 0};
    ndetections = 0;
    Stats st = {0, 0};
    long written = 0;

    for (int f = 0; f < sc->frames; f++) {
        if (f > 0) advance(&scene, sc->speed(f));
        history[f] = scene;
        render(frame, scene.list, scene.items);
        long id = ARMotionAddFrame(m, frame, W * 4, f / 60.0);
        assert(id == f);
        if (f % sc->period == 0 && deliverAt < 0) {
            pendingCount = (round++ == sc->skipRound) ? 0 : detect(&scene, pendingBoxes, pendingKeys);
            if (sc->missPercent) {
                int kept = 0;
                for (int i = 0; i < pendingCount; i++) {
                    if (mix(pendingKeys[i], (uint32_t)f, 99) % 100 < (uint32_t)sc->missPercent) continue;
                    pendingBoxes[kept] = pendingBoxes[i];
                    pendingKeys[kept++] = pendingKeys[i];
                }
                pendingCount = kept;
            }
            pendingFrame = f;
            deliverAt = f + sc->latency;
        }
        if (f == deliverAt) {
            ARMotionAddDetections(m, pendingFrame, pendingBoxes, pendingKeys, pendingCount);
            detectionFrames[ndetections] = pendingFrame;
            detectionCounts[ndetections] = pendingCount;
            memcpy(detectionKeys[ndetections], pendingKeys, sizeof(uint32_t) * (size_t)pendingCount);
            ndetections++;
            for (int i = 0; i < pendingCount; i++) {
                int known = 0;
                for (int k = 0; k < nseen; k++) known |= seen[k] == pendingKeys[i];
                if (!known && nseen < MAXI) seen[nseen++] = pendingKeys[i];
            }
            deliverAt = -1;
        }
        while (written <= f && ARMotionFrameReady(m, written, 0.35)) {
            writeFrame(m, written, history, &r, &st);
            ARMotionRelease(m, ++written);
        }
        if (sc->checkPrediction && ARMotionLatestDetectedFrame(m) >= 0) {
            ARBox out[MAXI];
            int n = ARMotionPredictedBoxes(m, 2, out, MAXI);
            // 只检查已经被识别过的内容（从未识别过的新内容无法预测）。
            for (int i = 0; i < scene.items; i++) {
                const Item *it = &scene.list[i];
                int known = 0;
                for (int k = 0; k < nseen; k++) known |= seen[k] == it->seed;
                if (known && it->sensitive && !itemCovered(out, n, it)) r.predictionMisses++;
            }
        }
    }
    // 结束：对最后一帧再识别一次，然后写完剩下的帧。
    int last = sc->frames - 1;
    ARBox finalBoxes[MAXI];
    uint32_t finalKeys[MAXI];
    int nfinal = detect(&history[last], finalBoxes, finalKeys);
    ARMotionAddDetections(m, last, finalBoxes, finalKeys, nfinal);
    detectionFrames[ndetections] = last;
    detectionCounts[ndetections] = nfinal;
    memcpy(detectionKeys[ndetections], finalKeys, sizeof(uint32_t) * (size_t)nfinal);
    ndetections++;
    for (; written <= last; written++) writeFrame(m, written, history, &r, &st);
    r.areaRatio = st.ratioN ? st.ratioSum / st.ratioN : 0;
    free(frame);
    free(history);
    ARMotionDestroy(m);
    return r;
}

static double still(int f) { (void)f; return 0; }
static double fast(int f) { (void)f; return 25; }                         // 每秒 1500 像素
static double veryFast(int f) { (void)f; return 45; }                     // 每秒 2700 像素
static double burst(int f) { return f < 20 ? 0 : f < 50 ? (f - 20) * 1.5 : f < 70 ? 45 : f < 100 ? (100 - f) * 1.5 : 0; }
static double jitter(int f) { return (f / 7) % 2 ? 30 : -18; }            // 来回滚动
static double fractional(int f) { (void)f; return 17.3; }                 // 非整数速度（画面缩放后常见）
static double slow(int f) { (void)f; return 3; }                          // 慢慢阅读时的滚动

int main(void) {
    struct { const char *name; Scenario sc; double maxRatio; } cases[] = {
        {"静止画面", {60, 6, 3, -1, still, 0, 0}, 1.3},
        {"快速滚动（1500 像素/秒）", {120, 6, 3, -1, fast, 0, 0}, 1.6},
        {"极快滚动（2700 像素/秒）", {120, 6, 3, -1, veryFast, 0, 0}, 1.8},
        {"加速、匀速、减速", {130, 6, 3, -1, burst, 0, 0}, 1.6},
        {"来回滚动", {120, 6, 3, -1, jitter, 0, 0}, 1.8},
        {"识别漏掉一次", {120, 6, 3, 5, fast, 0, 0}, 1.8},
        {"非整数速度（每帧 17.3 像素）", {120, 6, 3, -1, fractional, 0, 0}, 1.6},
        {"静止 + 识别时有时无（漏 60%）", {180, 6, 3, -1, still, 0, 60}, 1.3},
        {"慢速滚动 + 识别时有时无（漏 60%）", {180, 6, 3, -1, slow, 0, 60}, 1.3},
        {"识别慢（每 12 帧一次，延迟 8 帧）", {150, 12, 8, -1, fast, 0, 0}, 1.8},
    };
    int failed = 0;
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        Result r = run(&cases[i].sc);
        int ok = r.uncovered == 0 && r.areaRatio <= cases[i].maxRatio;
        printf("%s %-34s 漏遮 %d 处 · 遮挡面积为文字的 %.2f 倍", ok ? "✅" : "❌", cases[i].name, r.uncovered, r.areaRatio);
        if (r.unrecognizable) printf(" ·（从未完整出现、无法识别的半截文字 %d 处）", r.unrecognizable);
        printf("\n");
        failed += !ok;
    }
    struct { const char *name; Scenario sc; } live[] = {
        {"实时遮挡：快速滚动 + 按速度预测", {120, 6, 3, -1, fast, 1, 0}},
        {"实时遮挡：静止 + 识别时有时无（漏 60%）", {240, 6, 3, -1, still, 1, 60}},
        {"实时遮挡：慢速滚动 + 识别时有时无（漏 60%）", {240, 6, 3, -1, slow, 1, 60}},
    };
    for (size_t i = 0; i < sizeof live / sizeof live[0]; i++) {
        Result r = run(&live[i].sc);
        printf("%s %-36s 已识别过的内容漏遮 %d 帧次\n", r.predictionMisses == 0 ? "✅" : "❌", live[i].name, r.predictionMisses);
        failed += r.predictionMisses != 0;
    }
    printf(failed ? "\n%d failed\n" : "\nall passed\n", failed);
    return failed ? 1 : 0;
}
