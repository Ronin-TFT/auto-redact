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
	pos := func(t float64) Rect { return Rect{100, 800 - 1000*t, 200, 30} } // 每秒向上 1000 像素
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
	tr.Add(0.2, []Rect{{10, 10, 50, 20}})
	// 0.1 秒时文字可能已经出现：录屏模式使用之后的结果，提前遮住。
	if !covers(tr.BoxesAt(0.1), Rect{10, 10, 50, 20}) {
		t.Fatal("future detection not applied")
	}
}

func TestHoldBridgesMissedRecognition(t *testing.T) {
	tr := newTracker()
	tr.Hold = 0.5
	box := Rect{10, 10, 50, 20}
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
	tr.Add(0, []Rect{{0, 0, 40, 20}})
	tr.Add(0.2, []Rect{{900, 900, 300, 20}})
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
	tr.Add(0, []Rect{{-10, 90, 30, 30}, {20, 90, 10, 5}, {60, 10, 10, 10}})
	got := tr.BoxesAt(0)
	if len(got) != 2 {
		t.Fatalf("got %+v", got)
	}
	for _, b := range got {
		if b.X < 0 || b.Y < 0 || b.maxX() > 100 || b.maxY() > 100 {
			t.Fatalf("not clipped: %+v", b)
		}
	}
	if got[0] != (Rect{55, 5, 20, 20}) {
		t.Fatalf("padding: %+v", got[0])
	}
}

func TestHistoryIsPruned(t *testing.T) {
	tr := newTracker()
	for i := 0; i < 1000; i++ {
		tr.Add(float64(i)*0.1, []Rect{{1, 1, 1, 1}})
	}
	if len(tr.history) > 110 {
		t.Fatalf("history not pruned: %d", len(tr.history))
	}
}

func TestOutOfOrderAdd(t *testing.T) {
	tr := newTracker()
	tr.Add(0.4, []Rect{{0, 0, 10, 10}})
	tr.Add(0.2, []Rect{{50, 50, 10, 10}})
	if tr.Latest() != 0.4 || !covers(tr.BoxesAt(0.25), Rect{50, 50, 10, 10}) {
		t.Fatal("out of order")
	}
}
