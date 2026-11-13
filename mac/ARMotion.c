#include "ARMotion.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// 追踪参数（单位：缩小后的像素）。
enum {
    AR_SEARCH_Y = 40,    // 纵向搜索范围（以预测位置为中心）
    AR_SEARCH_X = 8,     // 横向搜索范围
    AR_MAX_PATCH_W = 160,
    AR_MAX_PATCH_H = 32,
};
static const double AR_MIN_MAX_COST = 10.0; // 匹配误差上限的下限（平均每像素灰度差）
static const double AR_COST_RATIO = 0.45;   // 匹配误差上限 = 模板对比度 × 此比例
static const double AR_MIN_OVERLAP = 0.4; // 目标位置至少有 40% 落在画面内才比较

typedef struct {
    ARBox box;
    uint32_t key;
    double vx, vy;     // 上一步的位移（原始像素/帧）
    double lastSeen;   // 最近一次被识别到的画面时间
    int lost;          // 连续追踪失败的帧数
    double lostSince;  // 开始追踪失败的画面时间
    int edge;          // 最近一步内容被画面边缘截断，位置是按速度推算的
} ARTrack;

typedef struct {
    long id;
    double time;
    uint8_t *gray;
    ARBox *boxes;
    int count, cap;
} ARFrame;

struct ARMotionSession {
    int width, height, factor, gw, gh;
    double padding, hold;
    ARFrame *frames;
    int nframes, capFrames;
    long nextId, lastDetected;
    ARTrack *tracks;
    int ntracks, capTracks;
};

// ---------------------------------------------------------------- 基础工具

static void frameAddBox(ARFrame *f, ARBox b) {
    if (f->count == f->cap) {
        f->cap = f->cap ? f->cap * 2 : 8;
        f->boxes = realloc(f->boxes, sizeof(ARBox) * (size_t)f->cap);
    }
    f->boxes[f->count++] = b;
}

static ARBox shiftBox(ARBox b, double dx, double dy) {
    b.x += dx;
    b.y += dy;
    return b;
}

static ARBox unionBox(ARBox a, ARBox b) {
    double x0 = fmin(a.x, b.x), y0 = fmin(a.y, b.y);
    double x1 = fmax(a.x + a.w, b.x + b.w), y1 = fmax(a.y + a.h, b.y + b.h);
    ARBox r = {x0, y0, x1 - x0, y1 - y0};
    return r;
}

static double overlapArea(ARBox a, ARBox b) {
    double w = fmin(a.x + a.w, b.x + b.w) - fmax(a.x, b.x);
    double h = fmin(a.y + a.h, b.y + b.h) - fmax(a.y, b.y);
    return (w > 0 && h > 0) ? w * h : 0;
}

static int boxesOverlap(ARBox a, ARBox b) { return overlapArea(a, b) > 0; }

static ARFrame *findFrame(const ARMotionSession *s, long id) {
    if (s->nframes == 0) return NULL;
    long idx = id - s->frames[0].id;
    if (idx < 0 || idx >= s->nframes) return NULL;
    return &s->frames[idx];
}

/// 追踪失败时显示的保守区域：按速度和搜索范围扩大。
static ARBox lostBox(const ARMotionSession *s, const ARTrack *t) {
    double mx = fabs(t->vx) + AR_SEARCH_X * s->factor, my = fabs(t->vy) + AR_SEARCH_Y * s->factor * 0.5;
    ARBox b = {t->box.x - mx, t->box.y - my, t->box.w + 2 * mx, t->box.h + 2 * my};
    return b;
}

static int leaving(const ARMotionSession *s, const ARTrack *t);

static int crossesEdge(const ARMotionSession *s, ARBox b) {
    return b.x < 0 || b.y < 0 || b.x + b.w > s->width || b.y + b.h > s->height;
}

/// 显示的打码框：追踪失败时放大到可能的范围。正在滚入或滚出画面时（跨过画面边缘），
/// 匹配失败是因为内容被画面边缘截断，移动方向和速度仍然可靠，只小幅放大。
static ARBox displayBox(const ARMotionSession *s, const ARTrack *t) {
    if (!t->lost && !t->edge) return t->box;
    if (t->lost && leaving(s, t)) return t->box;
    if (t->edge || crossesEdge(s, t->box)) {
        // 按速度推算的位置在加速、减速时会有偏差，按速度留出余量。
        double mx = fabs(t->vx) * 0.15 + 4, my = fabs(t->vy) * 0.15 + 4;
        ARBox b = {t->box.x - mx, t->box.y - my, t->box.w + 2 * mx, t->box.h + 2 * my};
        return b;
    }
    return lostBox(s, t);
}

// ---------------------------------------------------------------- 灰度与匹配

static uint8_t *makeGray(const ARMotionSession *s, const uint8_t *bgra, int bytesPerRow) {
    int f = s->factor, gw = s->gw, gh = s->gh;
    uint8_t *gray = malloc((size_t)gw * (size_t)gh);
    unsigned div = (unsigned)(f * f);
    for (int gy = 0; gy < gh; gy++) {
        uint8_t *out = gray + (size_t)gy * gw;
        for (int gx = 0; gx < gw; gx++) {
            unsigned sum = 0;
            for (int yy = 0; yy < f; yy++) {
                const uint8_t *p = bgra + (size_t)(gy * f + yy) * (size_t)bytesPerRow + (size_t)gx * f * 4;
                for (int xx = 0; xx < f; xx++, p += 4) sum += ((unsigned)p[2] * 77 + (unsigned)p[1] * 150 + (unsigned)p[0] * 29) >> 8;
            }
            out[gx] = (uint8_t)(sum / div);
        }
    }
    // 3×3 均值模糊（先横向后纵向）：滚动距离不是整数像素、或画面经过缩放时，
    // 相邻帧会错开半个像素，模糊后仍能匹配。
    uint16_t *row = malloc(sizeof(uint16_t) * (size_t)gw * (size_t)gh);
    for (int y = 0; y < gh; y++) {
        const uint8_t *in = gray + (size_t)y * gw;
        uint16_t *o = row + (size_t)y * gw;
        for (int x = 0; x < gw; x++) {
            int a = x > 0 ? x - 1 : x, b = x + 1 < gw ? x + 1 : x;
            o[x] = (uint16_t)(in[a] + in[x] + in[b]);
        }
    }
    for (int y = 0; y < gh; y++) {
        const uint16_t *up = row + (size_t)(y > 0 ? y - 1 : y) * gw, *mid = row + (size_t)y * gw;
        const uint16_t *down = row + (size_t)(y + 1 < gh ? y + 1 : y) * gw;
        uint8_t *o = gray + (size_t)y * gw;
        for (int x = 0; x < gw; x++) o[x] = (uint8_t)((up[x] + mid[x] + down[x]) / 9);
    }
    free(row);
    return gray;
}

typedef struct {
    int x0, y0, x1, y1; // 模板在源画面中的范围（缩小后的像素，左闭右开）
} ARPatch;

/// 平均绝对差；有效像素不足时返回 INFINITY。step 为采样间隔（粗搜索用 2）；
/// 平均误差已经超过 limit 时提前放弃。fraction 返回目标位置落在画面内的比例。
static double patchCostFraction(const ARMotionSession *s, const uint8_t *from, const uint8_t *to, ARPatch p, int dx, int dy,
                                int step, double limit, double *fraction) {
    int x0 = p.x0 > -dx ? p.x0 : -dx, x1 = p.x1 < s->gw - dx ? p.x1 : s->gw - dx;
    int y0 = p.y0 > -dy ? p.y0 : -dy, y1 = p.y1 < s->gh - dy ? p.y1 : s->gh - dy;
    long area = (long)(p.x1 - p.x0) * (p.y1 - p.y0);
    long valid = (x1 > x0 && y1 > y0) ? (long)(x1 - x0) * (y1 - y0) : 0;
    if (fraction) *fraction = area > 0 ? (double)valid / (double)area : 0;
    if (valid == 0 || valid < (long)(area * AR_MIN_OVERLAP)) return INFINITY;
    long sum = 0, count = 0;
    long budget = isfinite(limit) ? (long)(limit * (double)valid / ((double)step * step)) + 1 : -1;
    for (int y = y0; y < y1; y += step) {
        const uint8_t *src = from + (size_t)y * s->gw;
        const uint8_t *dst = to + (size_t)(y + dy) * s->gw + dx;
        for (int x = x0; x < x1; x += step) {
            int d = (int)src[x] - (int)dst[x];
            sum += d < 0 ? -d : d;
        }
        count += (x1 - x0 + step - 1) / step;
        if (budget >= 0 && sum > budget) return INFINITY;
    }
    return count ? (double)sum / (double)count : INFINITY;
}

static double patchCost(const ARMotionSession *s, const uint8_t *from, const uint8_t *to, ARPatch p, int dx, int dy) {
    return patchCostFraction(s, from, to, p, dx, dy, 1, INFINITY, NULL);
}

enum { AR_TRACK_FAILED = 0, AR_TRACK_OK = 1, AR_TRACK_AT_EDGE = 2 };

/// 在 to 画面中寻找 from 画面里 box 的内容，返回位移（原始像素）。
/// 成功返回 AR_TRACK_OK；内容正被画面边缘截断、位移不可靠时返回 AR_TRACK_AT_EDGE；失败返回 AR_TRACK_FAILED。
static int trackBox(const ARMotionSession *s, const uint8_t *from, const uint8_t *to, ARBox box,
                    double predictDx, double predictDy, double *outDx, double *outDy) {
    int f = s->factor;
    ARPatch p = {(int)floor(box.x / f), (int)floor(box.y / f), (int)ceil((box.x + box.w) / f), (int)ceil((box.y + box.h) / f)};
    // 只用中间一段，控制计算量。
    if (p.x1 - p.x0 > AR_MAX_PATCH_W) { int c = (p.x0 + p.x1) / 2; p.x0 = c - AR_MAX_PATCH_W / 2; p.x1 = p.x0 + AR_MAX_PATCH_W; }
    if (p.y1 - p.y0 > AR_MAX_PATCH_H) { int c = (p.y0 + p.y1) / 2; p.y0 = c - AR_MAX_PATCH_H / 2; p.y1 = p.y0 + AR_MAX_PATCH_H; }
    long fullArea = (long)(p.x1 - p.x0) * (p.y1 - p.y0);
    if (p.x0 < 0) p.x0 = 0;
    if (p.y0 < 0) p.y0 = 0;
    if (p.x1 > s->gw) p.x1 = s->gw;
    if (p.y1 > s->gh) p.y1 = s->gh;
    if (p.x1 - p.x0 < 3 || p.y1 - p.y0 < 2) return AR_TRACK_AT_EDGE;
    // 内容本身有三成以上在画面外：残缺的片段容易匹配到错误位置，沿用之前的速度。
    if ((long)(p.x1 - p.x0) * (p.y1 - p.y0) < fullArea * 0.7) return AR_TRACK_AT_EDGE;

    // 没有纹理（空白）无法追踪。
    long sum = 0, n = 0;
    for (int y = p.y0; y < p.y1; y++)
        for (int x = p.x0; x < p.x1; x++) { sum += from[(size_t)y * s->gw + x]; n++; }
    double mean = (double)sum / n, dev = 0;
    for (int y = p.y0; y < p.y1; y++)
        for (int x = p.x0; x < p.x1; x++) dev += fabs(from[(size_t)y * s->gw + x] - mean);
    double contrast = dev / n;
    if (contrast < 2.0) return AR_TRACK_FAILED;

    int pdx = (int)lround(predictDx / f), pdy = (int)lround(predictDy / f);
    // 粗搜索（隔一个像素采样）：先在预测的横向位置上做纵向搜索（滚动以纵向为主），
    // 再在最佳纵向位置附近搜索横向；最后逐像素细调。
    double coarse = INFINITY;
    int bestDx = pdx, bestDy = pdy;
    for (int dy = pdy - AR_SEARCH_Y; dy <= pdy + AR_SEARCH_Y; dy++) {
        double c = patchCostFraction(s, from, to, p, pdx, dy, 2, coarse, NULL);
        if (c < coarse || (c == coarse && abs(dy - pdy) < abs(bestDy - pdy))) { coarse = c; bestDy = dy; }
    }
    int baseDy = bestDy;
    for (int dy = baseDy - 1; dy <= baseDy + 1; dy++) {
        for (int dx = pdx - AR_SEARCH_X; dx <= pdx + AR_SEARCH_X; dx++) {
            double c = patchCostFraction(s, from, to, p, dx, dy, 2, coarse, NULL);
            if (c < coarse) { coarse = c; bestDx = dx; bestDy = dy; }
        }
    }
    double best = INFINITY;
    int cx = bestDx, cy = bestDy;
    for (int dy = cy - 1; dy <= cy + 1; dy++) {
        for (int dx = cx - 1; dx <= cx + 1; dx++) {
            double c = patchCostFraction(s, from, to, p, dx, dy, 1, best, NULL);
            if (c < best) { best = c; bestDx = dx; bestDy = dy; }
        }
    }
    double maxCost = fmax(AR_MIN_MAX_COST, contrast * AR_COST_RATIO);
    if (!(best <= maxCost)) return AR_TRACK_FAILED;
    // 目标位置有三成以上在画面外：只比较了残留的一部分，算出的位移偏向“少移动”，不可信。
    double fraction = 1;
    patchCostFraction(s, from, to, p, bestDx, bestDy, 1, INFINITY, &fraction);
    if (fraction < 0.7) return AR_TRACK_AT_EDGE;
    // 亚像素：在最佳位置两侧做抛物线插值。缩小后的一个像素对应原图 factor 个像素，
    // 不插值的话每一步都有取整误差，逐帧追踪会越漂越远。
    double fx = 0, fy = 0;
    double cyl = patchCost(s, from, to, p, bestDx, bestDy - 1), cyr = patchCost(s, from, to, p, bestDx, bestDy + 1);
    double cxl = patchCost(s, from, to, p, bestDx - 1, bestDy), cxr = patchCost(s, from, to, p, bestDx + 1, bestDy);
    if (isfinite(cyl) && isfinite(cyr)) {
        double denom = cyl - 2 * best + cyr;
        if (denom > 1e-9) fy = fmax(-0.5, fmin(0.5, (cyl - cyr) / (2 * denom)));
    }
    if (isfinite(cxl) && isfinite(cxr)) {
        double denom = cxl - 2 * best + cxr;
        if (denom > 1e-9) fx = fmax(-0.5, fmin(0.5, (cxl - cxr) / (2 * denom)));
    }
    *outDx = (bestDx + fx) * f;
    *outDy = (bestDy + fy) * f;
    return AR_TRACK_OK;
}

/// 把一个追踪从 from 推进到 to。
static void stepTrack(const ARMotionSession *s, ARTrack *t, const uint8_t *from, const uint8_t *to, double toTime) {
    double dx = 0, dy = 0;
    switch (trackBox(s, from, to, t->box, t->vx, t->vy, &dx, &dy)) {
    case AR_TRACK_OK:
        t->box = shiftBox(t->box, dx, dy);
        t->vx = dx;
        t->vy = dy;
        t->lost = 0;
        t->edge = 0;
        break;
    case AR_TRACK_AT_EDGE:
        // 正在滚入或滚出画面：沿用之前的速度。
        t->box = shiftBox(t->box, t->vx, t->vy);
        t->edge = 1;
        break;
    default:
        t->box = shiftBox(t->box, t->vx, t->vy);
        if (t->lost == 0) t->lostSince = toTime;
        t->lost++;
        break;
    }
}

/// 已完全离开画面（留出一个框高的余量，避免露出最后几个像素时就停止追踪）。
static int offscreen(const ARMotionSession *s, ARBox b) {
    double m = fmax(b.h, 16);
    return b.x + b.w < -m || b.y + b.h < -m || b.x > s->width + m || b.y > s->height + m;
}

/// 追踪失败且大部分在画面外（正在滚入或滚出）。
static int leaving(const ARMotionSession *s, const ARTrack *t) {
    if (!t->lost) return 0;
    ARBox screen = {0, 0, s->width, s->height};
    double area = t->box.w * t->box.h;
    return area <= 0 || overlapArea(t->box, screen) < area / 3;
}

// ---------------------------------------------------------------- 公开接口

ARMotionSession *ARMotionCreate(int width, int height, int factor, double padding, double hold) {
    if (width <= 0 || height <= 0) return NULL;
    if (factor < 1) factor = 1;
    ARMotionSession *s = calloc(1, sizeof(ARMotionSession));
    s->width = width;
    s->height = height;
    s->factor = factor;
    s->gw = width / factor;
    s->gh = height / factor;
    s->padding = padding;
    s->hold = hold;
    s->lastDetected = -1;
    return s;
}

void ARMotionDestroy(ARMotionSession *s) {
    if (!s) return;
    for (int i = 0; i < s->nframes; i++) {
        free(s->frames[i].gray);
        free(s->frames[i].boxes);
    }
    free(s->frames);
    free(s->tracks);
    free(s);
}

long ARMotionAddFrame(ARMotionSession *s, const uint8_t *bgra, int bytesPerRow, double time) {
    if (s->nframes == s->capFrames) {
        s->capFrames = s->capFrames ? s->capFrames * 2 : 32;
        s->frames = realloc(s->frames, sizeof(ARFrame) * (size_t)s->capFrames);
    }
    ARFrame *frame = &s->frames[s->nframes++];
    memset(frame, 0, sizeof(*frame));
    frame->id = s->nextId++;
    frame->time = time;
    frame->gray = makeGray(s, bgra, bytesPerRow);

    // 把现有追踪推进到这一帧；识别漏掉超过 hold 秒或移出画面的丢弃。
    ARFrame *prev = s->nframes >= 2 ? &s->frames[s->nframes - 2] : NULL;
    int kept = 0;
    for (int i = 0; i < s->ntracks; i++) {
        ARTrack t = s->tracks[i];
        if (prev && prev->id == frame->id - 1) stepTrack(s, &t, prev->gray, frame->gray, time);
        // 追踪确认原位置的画面还在，就一直保持（识别时有时无也不会闪）；
        // 画面变了（追踪失败）超过 hold 秒才撤掉。
        if ((t.lost && time - t.lostSince > s->hold) || offscreen(s, t.box)) continue;
        s->tracks[kept++] = t;
        frameAddBox(frame, displayBox(s, &t));
    }
    s->ntracks = kept;
    return frame->id;
}

void ARMotionAddDetections(ARMotionSession *s, long frameId, const ARBox *boxes, const uint32_t *keys, int count) {
    ARFrame *frame = findFrame(s, frameId);
    if (!frame) return;
    long idx = frame - s->frames;
    long previousDetected = s->lastDetected;
    for (int i = 0; i < count; i++) frameAddBox(frame, boxes[i]);

    ARTrack *fresh = calloc((size_t)(count > 0 ? count : 1), sizeof(ARTrack));
    (void)previousDetected;
    // 往回追踪：补上这些内容在之前每一帧的位置，一直追到移出画面（刚滚进画面、只露出半截、
    // 识别看不清的那些帧也能遮住）。连续追踪失败太久就停止。
    for (int i = 0; i < count; i++) {
        ARTrack t = {boxes[i], keys ? keys[i] : 0, 0, 0, frame->time, 0, 0, 0};
        double firstVx = 0, firstVy = 0;
        for (long j = idx - 1; j >= 0; j--) {
            stepTrack(s, &t, s->frames[j + 1].gray, s->frames[j].gray, s->frames[j].time);
            if (j == idx - 1 && !t.lost) { firstVx = t.vx; firstVy = t.vy; }
            if (offscreen(s, t.box) || (t.lost > 6 && !leaving(s, &t))) break;
            frameAddBox(&s->frames[j], displayBox(s, &t));
        }
        // 紧挨着的前一帧到这一帧的速度，作为往前追踪的初始预测（往回追踪的位移取反）。
        ARTrack forward = {boxes[i], t.key, -firstVx, -firstVy, frame->time, 0, 0, 0};
        fresh[i] = forward;
    }
    // 往前追踪：识别期间已经到达的帧。
    for (int i = 0; i < count; i++) {
        for (long j = idx + 1; j < s->nframes; j++) {
            stepTrack(s, &fresh[i], s->frames[j - 1].gray, s->frames[j].gray, s->frames[j].time);
            frameAddBox(&s->frames[j], displayBox(s, &fresh[i]));
        }
    }
    // 合并：被新结果覆盖的旧追踪丢弃；没被识别到的旧追踪保留到 hold 结束（识别偶尔漏掉时不露出）。
    int total = count + s->ntracks;
    ARTrack *merged = malloc(sizeof(ARTrack) * (size_t)(total > 0 ? total : 1));
    int n = 0;
    for (int i = 0; i < count; i++) merged[n++] = fresh[i];
    for (int i = 0; i < s->ntracks; i++) {
        ARTrack *old = &s->tracks[i];
        int replaced = 0;
        for (int k = 0; k < count && !replaced; k++) {
            if (old->key && old->key == fresh[k].key) replaced = 1;
            else if (overlapArea(old->box, fresh[k].box) > 0.2 * fmin(old->box.w * old->box.h, fresh[k].box.w * fresh[k].box.h)) replaced = 1;
        }
        // 新一次识别没找到、追踪也已跟丢：内容确实不在了。
        if (!replaced && !old->lost) merged[n++] = *old;
    }
    free(s->tracks);
    free(fresh);
    s->tracks = merged;
    s->ntracks = n;
    s->capTracks = total;
    if (frameId > s->lastDetected) s->lastDetected = frameId;
}

long ARMotionLatestDetectedFrame(const ARMotionSession *s) { return s->lastDetected; }

int ARMotionFrameReady(const ARMotionSession *s, long frameId, double minDelay) {
    const ARFrame *frame = findFrame(s, frameId);
    if (!frame || s->lastDetected <= frameId) return 0;
    const ARFrame *detected = findFrame(s, s->lastDetected);
    return detected && detected->time - frame->time >= minDelay;
}

/// 扩边、裁剪、合并重叠。
static int finishBoxes(const ARMotionSession *s, const ARBox *in, int n, ARBox *out, int max) {
    ARBox *tmp = malloc(sizeof(ARBox) * (size_t)(n > 0 ? n : 1));
    int m = 0;
    for (int i = 0; i < n; i++) {
        double x0 = fmax(0, in[i].x - s->padding), y0 = fmax(0, in[i].y - s->padding);
        double x1 = fmin(s->width, in[i].x + in[i].w + s->padding), y1 = fmin(s->height, in[i].y + in[i].h + s->padding);
        if (x1 > x0 && y1 > y0) { ARBox b = {x0, y0, x1 - x0, y1 - y0}; tmp[m++] = b; }
    }
    for (int changed = 1; changed;) {
        changed = 0;
        for (int i = 0; i < m && !changed; i++) {
            for (int j = i + 1; j < m; j++) {
                if (boxesOverlap(tmp[i], tmp[j])) {
                    tmp[i] = unionBox(tmp[i], tmp[j]);
                    tmp[j] = tmp[--m];
                    changed = 1;
                    break;
                }
            }
        }
    }
    int count = m < max ? m : max;
    memcpy(out, tmp, sizeof(ARBox) * (size_t)count);
    free(tmp);
    return count;
}

int ARMotionBoxesForFrame(const ARMotionSession *s, long frameId, ARBox *out, int max) {
    ARFrame *frame = findFrame(s, frameId);
    if (!frame) return 0;
    return finishBoxes(s, frame->boxes, frame->count, out, max);
}

int ARMotionPredictedBoxes(const ARMotionSession *s, double framesAhead, ARBox *out, int max) {
    if (s->ntracks == 0) return 0;
    ARBox *tmp = malloc(sizeof(ARBox) * (size_t)s->ntracks);
    for (int i = 0; i < s->ntracks; i++) {
        const ARTrack *t = &s->tracks[i];
        ARBox now = displayBox(s, t);
        tmp[i] = unionBox(now, shiftBox(now, t->vx * framesAhead, t->vy * framesAhead));
    }
    int n = finishBoxes(s, tmp, s->ntracks, out, max);
    free(tmp);
    return n;
}

void ARMotionRelease(ARMotionSession *s, long frameId) {
    int drop = 0;
    while (drop < s->nframes - 1 && s->frames[drop].id < frameId) {
        free(s->frames[drop].gray);
        free(s->frames[drop].boxes);
        drop++;
    }
    if (drop > 0) {
        memmove(s->frames, s->frames + drop, sizeof(ARFrame) * (size_t)(s->nframes - drop));
        s->nframes -= drop;
    }
}

int ARMotionFrameCount(const ARMotionSession *s) { return s->nframes; }
