package track

import (
	"math"
	"testing"
)

func covers(boxes []Rect, r Rect) bool {
	for _, b := range boxes {
		if b.X <= r.X && b.Y <= r.Y && b.maxX() >= r.maxX() && b.maxY() >= r.maxY() {
			return true
		}
	}
	return false
}

func newTracker() *Tracker {
	tr := New()
	tr.Padding = 0
	return tr
}

func TestReadyAndLatest(t *testing.T) {
	tr := newTracker()
	if tr.Ready(0) || !math.IsInf(tr.Latest(), -1) {
		t.Fatal("empty tracker should not be ready")
	}
	tr.Add(1.0, nil)
	if !tr.Ready(0.9) || !tr.Ready(1.0) || tr.Ready(1.1) {
		t.Fatal("Ready")
	}
}

// 文字在两次识别之间滚动：中间每一帧的真实位置都必须被遮住。
func TestScrollingTextIsCoveredOnEveryFrame(t *testing.T) {
	tr := newTracker()
	pos := func(t float64) Rect { return Rect{100, 800 - 1000*t, 200, 30, 0} } // 每秒向上 1000 像素
	for _, at := range []float64{0, 0.2, 0.4} {
		tr.Add(at, []Rect{pos(at)})
	}
	for f := 0.0; f <= 0.4; f += 1.0 / 60 {
		if !covers(tr.BoxesAt(f), pos(f)) {
			t.Fatalf("frame %.3f not covered: %+v vs %+v", f, tr.BoxesAt(f), pos(f))
		}
	}
}

func TestNewTextAppearsBetweenRecognitions(t *testing.T) {
	tr := newTracker()
	tr.Add(0, nil)
	tr.Add(0.2, []Rect{{10, 10, 50, 20, 0}})
	// 0.1 秒时文字可能已经出现：录屏模式使用之后的结果，提前遮住。
	if !covers(tr.BoxesAt(0.1), Rect{10, 10, 50, 20, 0}) {
		t.Fatal("future detection not applied")
	}
}

func TestHoldBridgesMissedRecognition(t *testing.T) {
	tr := newTracker()
	tr.Hold = 0.5
	box := Rect{10, 10, 50, 20, 0}
	tr.Add(0, []Rect{box})
	tr.Add(0.2, nil) // 这次识别漏掉了
	if !covers(tr.BoxesAt(0.3), box) {
		t.Fatal("hold should keep the box")
	}
	tr.Add(0.4, nil)
	tr.Add(0.6, nil)
	if covers(tr.BoxesAt(0.7), box) {
		t.Fatal("box should expire after hold")
	}
}

func TestDifferentTextIsNotJoined(t *testing.T) {
	tr := newTracker()
	tr.Add(0, []Rect{{0, 0, 40, 20, 0}})
	tr.Add(0.2, []Rect{{900, 900, 300, 20, 0}})
	for _, b := range tr.BoxesAt(0.1) {
		if b.W > 400 {
			t.Fatalf("unrelated boxes joined: %+v", b)
		}
	}
}

func TestPaddingClipAndMerge(t *testing.T) {
	tr := New()
	tr.Padding = 5
	tr.Width, tr.Height = 100, 100
	tr.Add(0, []Rect{{-10, 90, 30, 30, 0}, {20, 90, 10, 5, 0}, {60, 10, 10, 10, 0}})
	got := tr.BoxesAt(0)
	if len(got) != 2 {
		t.Fatalf("got %+v", got)
	}
	for _, b := range got {
		if b.X < 0 || b.Y < 0 || b.maxX() > 100 || b.maxY() > 100 {
			t.Fatalf("not clipped: %+v", b)
		}
	}
	if got[0] != (Rect{55, 5, 20, 20, 0}) {
		t.Fatalf("padding: %+v", got[0])
	}
}

func TestHistoryIsPruned(t *testing.T) {
	tr := newTracker()
	for i := 0; i < 1000; i++ {
		tr.Add(float64(i)*0.1, []Rect{{1, 1, 1, 1, 0}})
	}
	if len(tr.history) > 110 {
		t.Fatalf("history not pruned: %d", len(tr.history))
	}
}

func TestOutOfOrderAdd(t *testing.T) {
	tr := newTracker()
	tr.Add(0.4, []Rect{{0, 0, 10, 10, 0}})
	tr.Add(0.2, []Rect{{50, 50, 10, 10, 0}})
	if tr.Latest() != 0.4 || !covers(tr.BoxesAt(0.25), Rect{50, 50, 10, 10, 0}) {
		t.Fatal("out of order")
	}
}

// 多处同样大小的敏感信息一起快速滚动（两次识别之间移动的距离大于它们的间距），
// 每一处在中间每一帧的真实位置都必须被遮住。
func TestDenseFastScroll(t *testing.T) {
	tr := newTracker()
	const speed, spacing = 1500.0, 120.0 // 每秒 1500 像素；两处相距 120 像素
	positions := func(at float64) []Rect {
		var out []Rect
		for i := 0; i < 12; i++ {
			r := Rect{X: 300, Y: 100 + float64(i)*spacing - speed*at, W: 260, H: 28, Key: uint32(1000 + i)}
			if r.Y >= 0 && r.maxY() <= 1080 {
				out = append(out, r)
			}
		}
		return out
	}
	for at := 0.0; at <= 0.8001; at += 0.2 {
		tr.Add(at, positions(at))
	}
	for f := 0.0; f <= 0.8; f += 1.0 / 60 {
		for _, r := range positions(f) {
			if !covers(tr.BoxesAt(f), r) {
				t.Fatalf("frame %.3f: %+v not covered by %+v", f, r, tr.BoxesAt(f))
			}
		}
	}
}

// 内容完全相同、无法区分时（没有指纹），也必须全部遮住。
func TestDenseFastScrollWithoutKeys(t *testing.T) {
	tr := newTracker()
	pos := func(at float64) []Rect {
		var out []Rect
		for i := 0; i < 12; i++ {
			r := Rect{X: 300, Y: 100 + float64(i)*120 - 1500*at, W: 260, H: 28}
			if r.Y >= 0 && r.maxY() <= 1080 {
				out = append(out, r)
			}
		}
		return out
	}
	for at := 0.0; at <= 0.8001; at += 0.2 {
		tr.Add(at, pos(at))
	}
	for f := 0.0; f <= 0.6; f += 1.0 / 60 {
		for _, r := range pos(f) {
			if r.Y > 400 || r.Y < 300 {
				continue
			}
			if !covers(tr.BoxesAt(f), r) {
				t.Fatalf("frame %.3f: %+v not covered", f, r)
			}
		}
	}
}

// 静止画面里有很多同样大小的框时，不能把它们连成一大块。
func TestStaticDenseBoxesStaySmall(t *testing.T) {
	for _, keyed := range []bool{true, false} {
		tr := newTracker()
		var boxes []Rect
		for i := 0; i < 8; i++ {
			r := Rect{X: 300, Y: 100 + float64(i)*60, W: 260, H: 28}
			if keyed {
				r.Key = uint32(i + 1)
			}
			boxes = append(boxes, r)
		}
		tr.Add(0, boxes)
		tr.Add(0.2, boxes)
		for _, b := range tr.BoxesAt(0.1) {
			if b.H > 40 {
				t.Fatalf("keyed=%v: static boxes merged into %+v", keyed, b)
			}
		}
	}
}

// 重复出现的相同内容（同一个号码出现两次）滚动时都要遮住。
func TestDuplicateContentScroll(t *testing.T) {
	tr := newTracker()
	pos := func(at float64) []Rect {
		return []Rect{{X: 300, Y: 600 - 1000*at, W: 200, H: 28, Key: 7}, {X: 300, Y: 700 - 1000*at, W: 200, H: 28, Key: 7}}
	}
	tr.Add(0, pos(0))
	tr.Add(0.2, pos(0.2))
	for f := 0.0; f <= 0.2; f += 1.0 / 60 {
		for _, r := range pos(f) {
			if !covers(tr.BoxesAt(f), r) {
				t.Fatalf("frame %.3f: %+v not covered", f, r)
			}
		}
	}
}

// 实时遮挡：按速度预测文字接下来的位置。
func TestBoxesAheadPredictsScroll(t *testing.T) {
	tr := newTracker()
	pos := func(at float64) Rect { return Rect{X: 100, Y: 800 - 1000*at, W: 200, H: 28, Key: 42} }
	tr.Add(0, []Rect{pos(0)})
	tr.Add(0.2, []Rect{pos(0.2)})
	if covers(tr.BoxesAt(0.2), pos(0.35)) {
		t.Fatal("test setup: plain boxes should not reach the future position")
	}
	ahead := tr.BoxesAhead(0.2, 0.15)
	for f := 0.2; f <= 0.35; f += 1.0 / 60 {
		if !covers(ahead, pos(f)) {
			t.Fatalf("predicted boxes miss %.3f: %+v", f, ahead)
		}
	}
	still := newTracker()
	still.Add(0, []Rect{{X: 100, Y: 100, W: 200, H: 28, Key: 1}})
	still.Add(0.2, []Rect{{X: 100, Y: 100, W: 200, H: 28, Key: 1}})
	if got := still.BoxesAhead(0.2, 0.5); len(got) != 1 || got[0].H > 28 {
		t.Fatalf("static content should not grow: %+v", got)
	}
}
