// Package track 根据定期文字识别的结果，算出每一帧需要打码的区域。
//
// 识别不是每帧都做。录屏时视频延迟写入：一帧要等它前后两次识别都完成，
// 用两次结果的并集打码；同一块文字在两次识别之间移动时，取覆盖整段移动范围的外接矩形，
// 因此中间的帧也被完整遮住。实时遮挡模式没有“之后”的结果，只用之前的结果加保留时间。
package track

import (
	"math"
	"sort"
)

// Rect 是像素坐标（左上角为原点）的矩形。
type Rect struct {
	X, Y, W, H float64
}

func (r Rect) maxX() float64 { return r.X + r.W }
func (r Rect) maxY() float64 { return r.Y + r.H }

func union(a, b Rect) Rect {
	x, y := math.Min(a.X, b.X), math.Min(a.Y, b.Y)
	return Rect{x, y, math.Max(a.maxX(), b.maxX()) - x, math.Max(a.maxY(), b.maxY()) - y}
}

func (r Rect) inset(d float64) Rect { return Rect{r.X - d, r.Y - d, r.W + 2*d, r.H + 2*d} }

func (r Rect) clip(width, height float64) (Rect, bool) {
	x0, y0 := math.Max(0, r.X), math.Max(0, r.Y)
	x1, y1 := r.maxX(), r.maxY()
	if width > 0 {
		x1 = math.Min(width, x1)
	}
	if height > 0 {
		y1 = math.Min(height, y1)
	}
	if x1 <= x0 || y1 <= y0 {
		return Rect{}, false
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}, true
}

type entry struct {
	t     float64
	boxes []Rect
}

// Tracker 保存最近的识别结果。不是并发安全的，调用方需加锁。
type Tracker struct {
	// Hold 秒内的旧结果仍然保留，避免某次识别漏掉时打码框闪烁。
	Hold float64
	// Padding 每个打码框向外扩展的像素。
	Padding float64
	// MaxMove 两次识别之间同一块文字的最大移动距离（像素），超过则视为不同的文字。
	MaxMove float64
	// Width/Height 为画面大小，用于裁剪；为 0 时不裁剪。
	Width, Height float64

	history []entry
}

// New 返回默认参数的跟踪器。
func New() *Tracker {
	return &Tracker{Hold: 0.5, Padding: 6, MaxMove: 600}
}

// Add 记录在时间 t（秒）对画面做识别得到的打码区域。
func (tr *Tracker) Add(t float64, boxes []Rect) {
	e := entry{t: t, boxes: append([]Rect(nil), boxes...)}
	i := sort.Search(len(tr.history), func(i int) bool { return tr.history[i].t > t })
	tr.history = append(tr.history, entry{})
	copy(tr.history[i+1:], tr.history[i:])
	tr.history[i] = e
	// 只保留最近 10 秒。
	cut := 0
	for cut < len(tr.history) && tr.history[cut].t < t-10 {
		cut++
	}
	tr.history = tr.history[cut:]
}

// Reset 清空历史。
func (tr *Tracker) Reset() { tr.history = nil }

// Latest 返回最近一次识别的时间；没有时返回 -Inf。
func (tr *Tracker) Latest() float64 {
	if len(tr.history) == 0 {
		return math.Inf(-1)
	}
	return tr.history[len(tr.history)-1].t
}

// Ready 表示时间 t 的帧之后已经有识别结果，可以写入（录屏模式）。
func (tr *Tracker) Ready(t float64) bool { return tr.Latest() >= t }

// BoxesAt 返回时间 t 的帧需要打码的区域。没有更新的识别结果时，最近一次结果一直有效。
func (tr *Tracker) BoxesAt(t float64) []Rect {
	prevIdx := sort.Search(len(tr.history), func(i int) bool { return tr.history[i].t > t }) - 1
	var prev, next *entry
	if prevIdx >= 0 {
		prev = &tr.history[prevIdx]
	}
	if prevIdx+1 < len(tr.history) {
		next = &tr.history[prevIdx+1]
	}
	var out []Rect
	if prev != nil {
		out = append(out, prev.boxes...)
		// 保留时间内更早的结果（识别偶尔漏掉时不闪烁）。
		for i := prevIdx - 1; i >= 0 && t-tr.history[i].t <= tr.Hold; i-- {
			out = append(out, tr.history[i].boxes...)
		}
	}
	if next != nil {
		out = append(out, next.boxes...)
		if prev != nil {
			out = append(out, tr.motionHulls(prev.boxes, next.boxes)...)
		}
	}
	return tr.finish(out)
}

// motionHulls 把前后两次识别中大小相近、距离最近的框配对，返回覆盖整段移动的外接矩形。
func (tr *Tracker) motionHulls(a, b []Rect) []Rect {
	used := make([]bool, len(b))
	var out []Rect
	for _, ra := range a {
		best, bestDist := -1, math.Inf(1)
		for j, rb := range b {
			if used[j] || !similarSize(ra, rb) {
				continue
			}
			dist := math.Hypot(rb.X-ra.X, rb.Y-ra.Y)
			if dist < bestDist && dist <= tr.MaxMove {
				best, bestDist = j, dist
			}
		}
		if best >= 0 && bestDist > 0 {
			used[best] = true
			out = append(out, union(ra, b[best]))
		}
	}
	return out
}

func similarSize(a, b Rect) bool {
	ratio := func(x, y float64) float64 {
		if x <= 0 || y <= 0 {
			return math.Inf(1)
		}
		return math.Max(x, y) / math.Min(x, y)
	}
	return ratio(a.W, b.W) <= 1.35 && ratio(a.H, b.H) <= 1.35
}

// finish 扩展、裁剪并合并重叠的框。
func (tr *Tracker) finish(boxes []Rect) []Rect {
	var out []Rect
	for _, b := range boxes {
		r, ok := b.inset(tr.Padding).clip(tr.Width, tr.Height)
		if ok {
			out = append(out, r)
		}
	}
	return mergeOverlapping(out)
}

func overlaps(a, b Rect) bool {
	return a.X < b.maxX() && b.X < a.maxX() && a.Y < b.maxY() && b.Y < a.maxY()
}

func mergeOverlapping(boxes []Rect) []Rect {
	for changed := true; changed; {
		changed = false
		for i := 0; i < len(boxes) && !changed; i++ {
			for j := i + 1; j < len(boxes); j++ {
				if overlaps(boxes[i], boxes[j]) {
					boxes[i] = union(boxes[i], boxes[j])
					boxes = append(boxes[:j], boxes[j+1:]...)
					changed = true
					break
				}
			}
		}
	}
	sort.Slice(boxes, func(i, j int) bool {
		if boxes[i].Y != boxes[j].Y {
			return boxes[i].Y < boxes[j].Y
		}
		return boxes[i].X < boxes[j].X
	})
	return boxes
}
