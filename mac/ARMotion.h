// 逐帧追踪画面中的打码区域（纯 C，不依赖系统框架，可在任何平台测试）。
//
// 文字识别每秒只做几次，负责“找到”敏感信息；两次识别之间，逐帧比对相邻画面，
// 估算每个打码框内容的位移，让遮挡紧贴文字移动。
// 录屏时画面会缓存一小段：新识别到的内容会沿缓存的画面往回追踪，补上它之前每一帧的位置。
#ifndef AR_MOTION_H
#define AR_MOTION_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 像素矩形（左上角原点，原始分辨率）。
typedef struct {
    double x, y, w, h;
} ARBox;

typedef struct ARMotionSession ARMotionSession;

/// width/height 为画面像素大小；factor 为追踪用的缩小倍数（建议 2）。
/// padding 为每个打码框向外扩展的像素；hold 为识别漏掉后继续追踪的秒数。
ARMotionSession *ARMotionCreate(int width, int height, int factor, double padding, double hold);
void ARMotionDestroy(ARMotionSession *session);

/// 加入一帧 BGRA 画面，返回帧编号（从 0 递增）。会用上一帧把现有的追踪推进到这一帧。
long ARMotionAddFrame(ARMotionSession *session, const uint8_t *bgra, int bytesPerRow, double time);

/// 加入对编号为 frameId 的帧做文字识别的结果。keys 为内容指纹（可为 NULL）。
/// 结果会沿缓存的画面往回、往前追踪。frameId 已被释放时忽略。
void ARMotionAddDetections(ARMotionSession *session, long frameId, const ARBox *boxes, const uint32_t *keys, int count);

/// 最近一次加入识别结果的帧编号；没有时为 -1。
long ARMotionLatestDetectedFrame(const ARMotionSession *session);

/// 录屏用：帧 frameId 是否可以写入。要求之后已有识别结果，且该结果比这一帧晚至少 minDelay 秒，
/// 让刚滚进画面、当时还识别不到的内容，能被之后的识别往回追踪补上。
int ARMotionFrameReady(const ARMotionSession *session, long frameId, double minDelay);

/// 帧 frameId 需要打码的区域（已扩边、裁剪、合并），写入 out，返回个数（最多 max）。
int ARMotionBoxesForFrame(const ARMotionSession *session, long frameId, ARBox *out, int max);

/// 实时遮挡用：当前（最新一帧）的打码区域，并按追踪到的速度覆盖之后 framesAhead 帧会经过的位置。
int ARMotionPredictedBoxes(const ARMotionSession *session, double framesAhead, ARBox *out, int max);

/// 释放编号小于 frameId 的帧（最新一帧总会保留）。
void ARMotionRelease(ARMotionSession *session, long frameId);

/// 当前缓存的帧数（用于测试与调试）。
int ARMotionFrameCount(const ARMotionSession *session);

#ifdef __cplusplus
}
#endif

#endif
