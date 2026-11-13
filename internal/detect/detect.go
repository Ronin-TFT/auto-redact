// Package detect 在一行文字中查找需要打码的敏感信息，返回 UTF-16 偏移（与 NSString/NSRange 一致）。
package detect

import (
	"regexp"
	"sort"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// 敏感信息类型。
const (
	KindPhone    = "phone"    // 手机号（中国大陆与带 + 区号的号码）
	KindEmail    = "email"    // 邮箱
	KindIDCard   = "idcard"   // 中国居民身份证号（校验位）
	KindBankCard = "bankcard" // 银行卡号（Luhn 校验）
	KindSecret   = "secret"   // API 密钥、令牌、私钥
	KindPassword = "password" // “密码: xxx” 这类字段的值
	KindIP       = "ip"       // IPv4 地址
	KindKeyword  = "keyword"  // 自定义关键词
)

// AllKinds 按界面显示顺序列出全部类型。
var AllKinds = []string{KindPhone, KindEmail, KindIDCard, KindBankCard, KindSecret, KindPassword, KindIP, KindKeyword}

// Config 决定识别哪些类型。Kinds 为空时使用 DefaultKinds。
type Config struct {
	Kinds    []string `json:"kinds"`
	Keywords []string `json:"keywords"`
}

// DefaultKinds 默认开启的类型（IP 地址容易误伤版本号等，默认关闭）。
var DefaultKinds = []string{KindPhone, KindEmail, KindIDCard, KindBankCard, KindSecret, KindPassword, KindKeyword}

// Match 是一段需要打码的文字，Start/End 为 UTF-16 偏移，左闭右开。
type Match struct {
	Start int    `json:"start"`
	End   int    `json:"end"`
	Kind  string `json:"kind"`
}

// Detector 是编译好的识别器，可并发使用。
type Detector struct {
	kinds    map[string]bool
	keywords *regexp.Regexp
}

var (
	rePhoneCN   = regexp.MustCompile(`(?:\+?86[\s-]?)?1[3-9]\d(?:[\s-]?\d){8}`)
	rePhoneIntl = regexp.MustCompile(`\+\d{1,3}[\s-]?\(?\d{1,4}\)?(?:[\s-]?\d{2,4}){2,4}`)
	reEmail     = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}`)
	reIDCard    = regexp.MustCompile(`\d{17}[\dXx]`)
	reCard      = regexp.MustCompile(`\d(?:[\s-]?\d){12,18}`)
	reIP        = regexp.MustCompile(`(?:\d{1,3}\.){3}\d{1,3}`)
	reSecrets   = []*regexp.Regexp{
		regexp.MustCompile(`sk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_-]{20,}`),
		regexp.MustCompile(`(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}`),
		regexp.MustCompile(`github_pat_[A-Za-z0-9_]{30,}`),
		regexp.MustCompile(`(?:AKIA|ASIA)[0-9A-Z]{16}`),
		regexp.MustCompile(`xox[abprs]-[A-Za-z0-9-]{10,}`),
		regexp.MustCompile(`AIza[0-9A-Za-z_-]{35}`),
		regexp.MustCompile(`eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`),
		regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`),
		regexp.MustCompile(`(?:rk|pk|sk|whsec)_(?:live|test)_[A-Za-z0-9]{16,}`),
	}
	// 只打码字段的值（第 2 组）。
	reSecretField = regexp.MustCompile(`(?i)\b(api[_-]?key|secret[_-]?key|client[_-]?secret|access[_-]?key|auth[_-]?token|token|secret)\b["']?\s*[:=]\s*["']?([A-Za-z0-9_\-./+=]{8,})`)
	rePassword    = regexp.MustCompile(`(?i)(?:\b(?:password|passwd|pwd|pass)\b|密码|口令|密钥|验证码)["']?\s*[:=：]\s*["']?([^\s"'，。,;；]{3,})`)
)

// New 根据配置创建识别器。
func New(cfg Config) *Detector {
	kinds := cfg.Kinds
	if len(kinds) == 0 {
		kinds = DefaultKinds
	}
	d := &Detector{kinds: map[string]bool{}}
	for _, k := range kinds {
		d.kinds[k] = true
	}
	var words []string
	for _, w := range cfg.Keywords {
		if w = strings.TrimSpace(w); w != "" {
			words = append(words, regexp.QuoteMeta(w))
		}
	}
	if len(words) > 0 && d.kinds[KindKeyword] {
		sort.Slice(words, func(i, j int) bool { return len(words[i]) > len(words[j]) })
		d.keywords = regexp.MustCompile(`(?i)` + strings.Join(words, "|"))
	}
	return d
}

type span struct {
	start, end int // 字节偏移
	kind       string
}

// Find 返回 text 中需要打码的位置，按起点排序，重叠的合并。
func (d *Detector) Find(text string) []Match {
	if text == "" {
		return nil
	}
	digits := normalizeDigits(text)
	var spans []span
	add := func(start, end int, kind string) { spans = append(spans, span{start, end, kind}) }
	isDigitAt := func(i int) bool { return i >= 0 && i < len(digits) && digits[i] >= '0' && digits[i] <= '9' }
	isWordAt := func(i int) bool {
		if i < 0 || i >= len(text) {
			return false
		}
		c := text[i]
		return c == '_' || c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z'
	}
	// 数字类：前后不能紧挨着其他数字。
	digitMatches := func(re *regexp.Regexp, kind string, valid func(string) bool) {
		for _, m := range re.FindAllStringIndex(digits, -1) {
			if isDigitAt(m[0]-1) || isDigitAt(m[1]) {
				continue
			}
			if valid == nil || valid(onlyDigits(digits[m[0]:m[1]])) {
				add(m[0], m[1], kind)
			}
		}
	}

	if d.kinds[KindIDCard] {
		digitMatches(reIDCard, KindIDCard, validIDCard)
	}
	if d.kinds[KindPhone] {
		digitMatches(rePhoneCN, KindPhone, nil)
		for _, m := range rePhoneIntl.FindAllStringIndex(digits, -1) {
			if !isDigitAt(m[1]) && len(onlyDigits(digits[m[0]:m[1]])) >= 8 {
				add(m[0], m[1], KindPhone)
			}
		}
	}
	if d.kinds[KindBankCard] {
		digitMatches(reCard, KindBankCard, func(s string) bool { return len(s) >= 13 && len(s) <= 19 && luhn(s) })
	}
	if d.kinds[KindEmail] {
		for _, m := range reEmail.FindAllStringIndex(text, -1) {
			add(m[0], m[1], KindEmail)
		}
	}
	if d.kinds[KindSecret] {
		for _, re := range reSecrets {
			for _, m := range re.FindAllStringIndex(text, -1) {
				if !isWordAt(m[0]-1) || strings.HasPrefix(text[m[0]:], "-----") {
					add(m[0], m[1], KindSecret)
				}
			}
		}
		for _, m := range reSecretField.FindAllStringSubmatchIndex(text, -1) {
			add(m[4], m[5], KindSecret)
		}
	}
	if d.kinds[KindPassword] {
		for _, m := range rePassword.FindAllStringSubmatchIndex(text, -1) {
			add(m[2], m[3], KindPassword)
		}
	}
	if d.kinds[KindIP] {
		for _, m := range reIP.FindAllStringIndex(text, -1) {
			if isDigitAt(m[0]-1) || isDigitAt(m[1]) || (m[0] > 0 && text[m[0]-1] == '.') || (m[1] < len(text) && text[m[1]] == '.') {
				continue
			}
			if validIPv4(text[m[0]:m[1]]) {
				add(m[0], m[1], KindIP)
			}
		}
	}
	if d.keywords != nil {
		for _, m := range d.keywords.FindAllStringIndex(text, -1) {
			add(m[0], m[1], KindKeyword)
		}
	}
	return toUTF16(text, mergeSpans(spans))
}

// normalizeDigits 把紧挨着数字、容易被 OCR 认错的字母换成数字（O/o/D→0，l/I/|→1，Z/z→2，S/s→5，B→8，g/q→9）。
// 长度不变，偏移不受影响。小字、浅色字识别时最容易出现这类错误。
func normalizeDigits(s string) string {
	b := []byte(s)
	isDigit := func(i int) bool { return i >= 0 && i < len(b) && b[i] >= '0' && b[i] <= '9' }
	for i, c := range b {
		var r byte
		switch c {
		case 'O', 'o', 'D':
			r = '0'
		case 'l', 'I', '|':
			r = '1'
		case 'Z', 'z':
			r = '2'
		case 'S', 's':
			r = '5'
		case 'B':
			r = '8'
		case 'g', 'q':
			r = '9'
		default:
			continue
		}
		if isDigit(i-1) || isDigit(i+1) {
			b[i] = r
		}
	}
	return string(b)
}

func onlyDigits(s string) string {
	var b strings.Builder
	for _, c := range s {
		if c >= '0' && c <= '9' || c == 'X' || c == 'x' {
			b.WriteRune(c)
		}
	}
	return b.String()
}

func luhn(s string) bool {
	sum, double := 0, false
	for i := len(s) - 1; i >= 0; i-- {
		c := s[i]
		if c < '0' || c > '9' {
			return false
		}
		n := int(c - '0')
		if double {
			n *= 2
			if n > 9 {
				n -= 9
			}
		}
		sum += n
		double = !double
	}
	return sum%10 == 0
}

// validIDCard 校验 18 位身份证：出生月日合理且校验位正确。
func validIDCard(s string) bool {
	if len(s) != 18 {
		return false
	}
	month := int(s[10]-'0')*10 + int(s[11]-'0')
	day := int(s[12]-'0')*10 + int(s[13]-'0')
	if month < 1 || month > 12 || day < 1 || day > 31 {
		return false
	}
	weights := []int{7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2}
	sum := 0
	for i, w := range weights {
		sum += int(s[i]-'0') * w
	}
	check := "10X98765432"[sum%11]
	last := s[17]
	if last == 'x' {
		last = 'X'
	}
	return last == check
}

func validIPv4(s string) bool {
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if len(p) > 1 && p[0] == '0' {
			return false
		}
		n := 0
		for _, c := range p {
			n = n*10 + int(c-'0')
		}
		if n > 255 {
			return false
		}
	}
	return true
}

// mergeSpans 排序并合并重叠或相接的区间，保留先出现的类型。
func mergeSpans(spans []span) []span {
	if len(spans) == 0 {
		return nil
	}
	sort.SliceStable(spans, func(i, j int) bool {
		if spans[i].start != spans[j].start {
			return spans[i].start < spans[j].start
		}
		return spans[i].end > spans[j].end
	})
	out := []span{spans[0]}
	for _, s := range spans[1:] {
		last := &out[len(out)-1]
		if s.start <= last.end {
			if s.end > last.end {
				last.end = s.end
			}
			continue
		}
		out = append(out, s)
	}
	return out
}

// toUTF16 把字节偏移换算成 UTF-16 偏移。
func toUTF16(text string, spans []span) []Match {
	if len(spans) == 0 {
		return nil
	}
	offsets := make([]int, len(text)+1)
	u := 0
	for i := 0; i < len(text); {
		r, size := utf8.DecodeRuneInString(text[i:])
		for k := 0; k < size; k++ {
			offsets[i+k] = u
		}
		u += len(utf16.Encode([]rune{r}))
		i += size
	}
	offsets[len(text)] = u
	out := make([]Match, len(spans))
	for i, s := range spans {
		out[i] = Match{Start: offsets[s.start], End: offsets[s.end], Kind: s.kind}
	}
	return out
}
