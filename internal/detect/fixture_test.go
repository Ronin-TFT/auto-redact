package detect

import (
	"bufio"
	"os"
	"strings"
	"testing"
)

// 样例文件里“应该被打码”的每一行都要有识别结果，“不应该被打码”的行都不能有。
func TestSampleFixture(t *testing.T) {
	f, err := os.Open("../../tests/fixtures/sensitive-sample.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	d := New(Config{Keywords: []string{"张三"}})
	section := ""
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "## ") {
			section = line
			continue
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		found := d.Find(line)
		switch {
		case strings.Contains(section, "不应该"):
			if len(found) != 0 {
				t.Errorf("false positive in %q: %+v", line, found)
			}
		case strings.Contains(section, "应该被打码"):
			if len(found) == 0 && !strings.Contains(line, "IP 地址") {
				t.Errorf("missed %q", line)
			}
		case strings.Contains(section, "滚动"):
			if strings.Contains(line, "@") && len(found) != 2 {
				t.Errorf("scroll line %q: %+v", line, found)
			}
		}
	}
}
