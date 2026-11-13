// 用 C 调用 Go 静态库，测试识别接口。
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

    puts("bridge configure and find passed");
    return 0;
}
