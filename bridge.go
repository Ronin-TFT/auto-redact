// 自动打码的识别与跟踪引擎，编译为静态库（go build -buildmode=c-archive）供 macOS App 调用。
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
	"autoredact/internal/track"
)

var (
	mu       sync.Mutex
	detector = detect.New(detect.Config{})
	tracker  = track.New()
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

// ARTrackReset 清空跟踪历史并设置参数：画面像素大小、扩展像素、保留秒数。
//
//export ARTrackReset
func ARTrackReset(width, height, padding, hold C.double) {
	mu.Lock()
	defer mu.Unlock()
	tracker = track.New()
	tracker.Width, tracker.Height = float64(width), float64(height)
	tracker.Padding, tracker.Hold = float64(padding), float64(hold)
	tracker.MaxMove = 0.6 * float64(height)
	if tracker.MaxMove <= 0 {
		tracker.MaxMove = 600
	}
}

// decodeRects 读取 [[x,y,w,h],...] 或带内容指纹的 [[x,y,w,h,key],...]。
func decodeRects(s string) []track.Rect {
	var raw [][]float64
	if json.Unmarshal([]byte(s), &raw) != nil {
		return nil
	}
	rects := make([]track.Rect, 0, len(raw))
	for _, r := range raw {
		if len(r) < 4 {
			continue
		}
		rect := track.Rect{X: r[0], Y: r[1], W: r[2], H: r[3]}
		if len(r) >= 5 && r[4] > 0 && r[4] < 1<<32 {
			rect.Key = uint32(r[4])
		}
		rects = append(rects, rect)
	}
	return rects
}

func encodeRects(boxes []track.Rect) *C.char {
	out := make([][4]float64, len(boxes))
	for i, b := range boxes {
		out[i] = [4]float64{b.X, b.Y, b.W, b.H}
	}
	return jsonString(out)
}

// ARTrackAdd 记录时间 t（秒）的识别结果 [[x,y,w,h,key],...]（像素，左上角原点；key 为内容指纹，可省略）。
//
//export ARTrackAdd
func ARTrackAdd(t C.double, boxesJSON *C.char) {
	rects := decodeRects(C.GoString(boxesJSON))
	mu.Lock()
	tracker.Add(float64(t), rects)
	mu.Unlock()
}

// ARTrackLatest 返回最近一次识别的时间，没有时返回 -1e300。
//
//export ARTrackLatest
func ARTrackLatest() C.double {
	mu.Lock()
	defer mu.Unlock()
	if latest := tracker.Latest(); latest > -1e300 {
		return C.double(latest)
	}
	return -1e300
}

// ARTrackBoxes 返回时间 t 的帧需要打码的区域 [[x,y,w,h],...]。
//
//export ARTrackBoxes
func ARTrackBoxes(t C.double) *C.char {
	mu.Lock()
	boxes := tracker.BoxesAt(float64(t))
	mu.Unlock()
	return encodeRects(boxes)
}

// ARTrackBoxesAhead 用于实时遮挡：在时间 t 的结果之外，按滚动速度预测 ahead 秒内文字经过的位置。
//
//export ARTrackBoxesAhead
func ARTrackBoxesAhead(t, ahead C.double) *C.char {
	mu.Lock()
	boxes := tracker.BoxesAhead(float64(t), float64(ahead))
	mu.Unlock()
	return encodeRects(boxes)
}

//export ARFree
func ARFree(s *C.char) {
	C.free(unsafe.Pointer(s))
}
