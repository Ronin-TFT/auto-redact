// 自动打码的识别引擎，编译为静态库（go build -buildmode=c-archive）供 macOS App 调用。
// 所有数据以 JSON 字符串传递；返回的字符串需要用 ARFree 释放。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"sync"
	"unsafe"

	"autoredact/internal/detect"
)

var (
	mu       sync.Mutex
	detector = detect.New(detect.Config{})
)

func main() {}

func jsonString(v interface{}) *C.char {
	data, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"error":"encode"}`)
	}
	return C.CString(string(data))
}

// ARConfigure 设置识别类型与关键词，例如 {"kinds":["phone","email"],"keywords":["张三"]}。
// 成功返回 NULL，失败返回错误信息。
//
//export ARConfigure
func ARConfigure(configJSON *C.char) *C.char {
	var cfg detect.Config
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &cfg); err != nil {
		return C.CString("配置格式错误：" + err.Error())
	}
	d := detect.New(cfg)
	mu.Lock()
	detector = d
	mu.Unlock()
	return nil
}

// ARFind 识别一批文字行。输入 ["行1","行2"]，输出 [[{start,end,kind}...], ...]（UTF-16 偏移）。
//
//export ARFind
func ARFind(linesJSON *C.char) *C.char {
	var lines []string
	if err := json.Unmarshal([]byte(C.GoString(linesJSON)), &lines); err != nil {
		return C.CString("[]")
	}
	mu.Lock()
	d := detector
	mu.Unlock()
	out := make([][]detect.Match, len(lines))
	for i, line := range lines {
		out[i] = d.Find(line)
		if out[i] == nil {
			out[i] = []detect.Match{}
		}
	}
	return jsonString(out)
}

//export ARFree
func ARFree(s *C.char) {
	C.free(unsafe.Pointer(s))
}
