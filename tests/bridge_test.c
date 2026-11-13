// 用 C 调用 Go 静态库，测试识别与跟踪接口。
// 构建：
//   go build -buildmode=c-archive -o build/libredact.a .
//   cc -I build tests/bridge_test.c build/libredact.a -lpthread -o build/bridge-test && build/bridge-test
// macOS 还需加 -framework CoreFoundation
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "libredact.h"

int main(void) {
    char *err = ARConfigure("{\"kinds\":[\"phone\",\"email\",\"keyword\"],\"keywords\":[\"张三\"]}");
    assert(err == NULL);
    char *found = ARFind("[\"张三 13800138000\",\"nothing here\",\"a@b.io\"]");
    assert(strcmp(found, "[[{\"start\":0,\"end\":2,\"kind\":\"keyword\"},{\"start\":3,\"end\":14,\"kind\":\"phone\"}],[],[{\"start\":0,\"end\":6,\"kind\":\"email\"}]]") == 0);
    ARFree(found);
    err = ARConfigure("not json");
    assert(err != NULL);
    ARFree(err);
    found = ARFind("broken");
    assert(strcmp(found, "[]") == 0);
    ARFree(found);

    ARTrackReset(1000, 800, 0, 0.5);
    assert(ARTrackLatest() < -1e299);
    ARTrackAdd(0.0, "[[100,500,200,30]]");
    ARTrackAdd(0.2, "[[100,300,200,30]]");
    assert(ARTrackLatest() == 0.2);
    char *boxes = ARTrackBoxes(0.1);
    // 两次识别之间的帧被覆盖整段移动的矩形遮住。
    assert(strcmp(boxes, "[[100,300,200,230]]") == 0);
    ARFree(boxes);
    // 没有更新的识别结果时，最近一次结果一直有效（宁可多遮，不能漏遮）。
    boxes = ARTrackBoxes(5.0);
    assert(strcmp(boxes, "[[100,300,200,30]]") == 0);
    ARFree(boxes);

    // 带内容指纹的滚动：两处内容不同的文字一起向上移动 300 像素。
    ARTrackReset(1000, 800, 0, 0.5);
    ARTrackAdd(0.0, "[[100,500,200,30,11],[100,620,200,30,22]]");
    ARTrackAdd(0.2, "[[100,200,200,30,11],[100,320,200,30,22]]");
    boxes = ARTrackBoxes(0.1);
    assert(strcmp(boxes, "[[100,200,200,450]]") == 0);
    ARFree(boxes);
    boxes = ARTrackBoxesAhead(0.2, 0.1);
    assert(strstr(boxes, "[100,50,") != NULL);
    ARFree(boxes);

    puts("bridge configure, find and track passed");
    return 0;
}
