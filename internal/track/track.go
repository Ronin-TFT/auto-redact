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

// Rect 是像素坐标（左上角为原点）的矩形。Key 是这处文字内容的指纹（哈希），
// 用来在前后两次识别之间找到同一处文字；0 表示未知。
type Rect struct {
	X, Y, W, H float64
	Key        uint32
}

func (r Rect) shift(dx, dy float64) Rect { return Rect{r.X + dx, r.Y + dy, r.W, r.H, r.Key} }

func (r Rect) maxX() float64 { return r.X + r.W }
func (r Rect) maxY() float64 { return r.Y + r.H }

func union(a, b Rect) Rect {
	x, y := math.Min(a.X, b.X), math.Min(a.Y, b.Y)
	return Rect{x, y, math.Max(a.maxX(), b.maxX()) - x, math.Max(a.maxY(), b.maxY()) - y, 0}
}

func (r Rect) inset(d float64) Rect { return Rect{r.X - d, r.Y - d, r.W + 2*d, r.H + 2*d, 0} }

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
	return Rect{x0, y0, x1 - x0, y1 - y0, 0}, true
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

// motionHulls 返回覆盖文字在两次识别之间移动范围的外接矩形。
//
// 先按内容指纹配对（同一处文字前后各出现一次时最可靠）；用这些配对估算整体滚动量，
// 给刚滚入或滚出画面、只出现一次的文字补上移动范围；同样内容出现多次时无法区分，
// 与每个候选都取外接矩形（宁可多遮）。没有指纹时按大小和位置保守处理。
func (tr *Tracker) motionHulls(a, b []Rect) []Rect {
	var out []Rect
	dx, dy, haveShift := tr.estimateShift(a, b)
	matched := make([]bool, len(b))
	for _, ra := range a {
		tol := math.Max(4, ra.H/2)
		var same []int
		if ra.Key != 0 {
			for j, rb := range b {
				if rb.Key == ra.Key && similarSize(ra, rb) && tr.within(ra, rb) {
					same = append(same, j)
				}
			}
		}
		switch {
		case len(same) > 0:
			for _, j := range same {
				matched[j] = true
				if displacement(ra, b[j]) > tol {
					out = append(out, union(ra, b[j]))
				}
			}
		case haveShift:
			out = append(out, union(ra, ra.shift(dx, dy)))
		default:
			// 没有可靠信息：附近有几乎不动的同尺寸框就认为静止，否则与所有候选取外接矩形。
			var candidates []Rect
			static := false
			for _, rb := range b {
				if similarSize(ra, rb) && tr.within(ra, rb) {
					if displacement(ra, rb) <= tol {
						static = true
						break
					}
					candidates = append(candidates, rb)
				}
			}
			if !static {
				for _, rb := range candidates {
					out = append(out, union(ra, rb))
				}
			}
		}
	}
	if haveShift {
		for j, rb := range b {
			if !matched[j] {
				out = append(out, union(rb.shift(-dx, -dy), rb))
			}
		}
	}
	return out
}

// estimateShift 用前后各只出现一次的同一内容估算整体移动量（取中位数）。
func (tr *Tracker) estimateShift(a, b []Rect) (float64, float64, bool) {
	count := func(rs []Rect) map[uint32]int {
		m := map[uint32]int{}
		for _, r := range rs {
			if r.Key != 0 {
				m[r.Key]++
			}
		}
		return m
	}
	ca, cb := count(a), count(b)
	var xs, ys []float64
	for _, ra := range a {
		if ra.Key == 0 || ca[ra.Key] != 1 || cb[ra.Key] != 1 {
			continue
		}
		for _, rb := range b {
			if rb.Key == ra.Key && similarSize(ra, rb) && tr.within(ra, rb) {
				xs = append(xs, rb.X-ra.X)
				ys = append(ys, rb.Y-ra.Y)
			}
		}
	}
	if len(xs) == 0 {
		return 0, 0, false
	}
	return median(xs), median(ys), true
}

func median(v []float64) float64 {
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

func displacement(a, b Rect) float64 { return math.Hypot(b.X-a.X, b.Y-a.Y) }

func (tr *Tracker) within(a, b Rect) bool { return displacement(a, b) <= tr.MaxMove }

// BoxesAhead 用于实时遮挡：在最近的结果之外，按最近两次识别估算的移动速度，
// 预测 ahead 秒后文字的位置，并覆盖从现在到那时的移动范围。
func (tr *Tracker) BoxesAhead(t, ahead float64) []Rect {
	boxes := tr.BoxesAt(t)
	n := len(tr.history)
	if n < 2 || ahead <= 0 {
		return boxes
	}
	prev, last := tr.history[n-2], tr.history[n-1]
	dt := last.t - prev.t
	if dt <= 0 || dt > 2 {
		return boxes
	}
	dx, dy, ok := tr.estimateShift(prev.boxes, last.boxes)
	if !ok || math.Hypot(dx, dy) < 2 {
		return boxes
	}
	vx, vy := dx/dt, dy/dt
	var predicted []Rect
	for _, r := range last.boxes {
		predicted = append(predicted, union(r, r.shift(vx*ahead, vy*ahead)))
	}
	return tr.finish(append(boxes, predicted...))
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
