package detect

import (
	"testing"
	"unicode/utf16"
)

// found 返回被打码的文字片段。
func found(t *testing.T, d *Detector, text string) []string {
	t.Helper()
	u := utf16.Encode([]rune(text))
	var out []string
	for _, m := range d.Find(text) {
		if m.Start < 0 || m.End > len(u) || m.Start >= m.End {
			t.Fatalf("bad range %+v for %q", m, text)
		}
		out = append(out, string(utf16.Decode(u[m.Start:m.End])))
	}
	return out
}

func expect(t *testing.T, d *Detector, text string, want ...string) {
	t.Helper()
	got := found(t, d, text)
	if len(got) != len(want) {
		t.Fatalf("%q: got %q, want %q", text, got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("%q: got %q, want %q", text, got, want)
		}
	}
}

func TestPhones(t *testing.T) {
	d := New(Config{})
	expect(t, d, "电话：13800138000，备用 138 0013 8000", "13800138000", "138 0013 8000")
	expect(t, d, "+86 139-1234-5678 联系", "+86 139-1234-5678")
	expect(t, d, "Call +1 415 555 2671 now", "+1 415 555 2671")
	expect(t, d, "订单号 213800138000123 不是手机号")
	expect(t, d, "版本 12345678901")
}

func TestOCRDigitConfusion(t *testing.T) {
	d := New(Config{})
	expect(t, d, "手机 1380O138OOO", "1380O138OOO")
	expect(t, d, "Hello World OOO lll")
	expect(t, d, "电话 138OOl3BOOO", "138OOl3BOOO")
	expect(t, d, "1S8 0Z13 8000", "1S8 0Z13 8000")
	expect(t, d, "gross sales 2024 Q3")
}

func TestEmailAndKeywords(t *testing.T) {
	d := New(Config{Keywords: []string{"张三", "Acme Corp"}})
	expect(t, d, "发给 zhang.san+work@example.com.cn 或张三", "zhang.san+work@example.com.cn", "张三")
	expect(t, d, "ACME corp internal", "ACME corp")
	expect(t, d, "📞 emoji 前缀 a@b.io", "a@b.io")
}

func TestIDCardAndBankCard(t *testing.T) {
	d := New(Config{})
	expect(t, d, "身份证 11010519491231002X 已登记", "11010519491231002X")
	expect(t, d, "身份证 110105194912310021 校验位错误")
	expect(t, d, "卡号 4111 1111 1111 1111 有效期", "4111 1111 1111 1111")
	expect(t, d, "卡号 6222 0212 3456 7890 校验失败")
	expect(t, d, "时间戳 1700000000000")
}

func TestSecrets(t *testing.T) {
	d := New(Config{})
	expect(t, d, "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz123456", "sk-proj-abcdefghijklmnopqrstuvwxyz123456")
	expect(t, d, "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_abcdefghijklmnopqrstuvwxyz0123456789")
	expect(t, d, "aws AKIAIOSFODNN7EXAMPLE key", "AKIAIOSFODNN7EXAMPLE")
	expect(t, d, `"client_secret": "Zx9-vQ2.mN8pL4k"`, "Zx9-vQ2.mN8pL4k")
	expect(t, d, "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----")
	expect(t, d, "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop")
	expect(t, d, "task-list ask-me desk-lamp")
}

func TestPasswords(t *testing.T) {
	d := New(Config{})
	expect(t, d, "Wi-Fi 密码：hello2024，记得改", "hello2024")
	expect(t, d, "password = hunter22", "hunter22")
	expect(t, d, "验证码: 482913", "482913")
	expect(t, d, "忘记密码？点这里")
}

func TestIPAndKinds(t *testing.T) {
	expect(t, New(Config{}), "server 192.168.1.20 ok")
	d := New(Config{Kinds: []string{KindIP}})
	expect(t, d, "server 192.168.1.20 and 10.0.0.1", "192.168.1.20", "10.0.0.1")
	expect(t, d, "version 1.2.3.4.5 and 999.1.1.1")
	expect(t, d, "13800138000 a@b.io")
	only := New(Config{Kinds: []string{KindEmail}})
	expect(t, only, "13800138000 a@b.io", "a@b.io")
}

func TestOverlapsMerge(t *testing.T) {
	d := New(Config{Keywords: []string{"example"}})
	expect(t, d, "mail me@example.com", "me@example.com")
}

func TestUTF16Offsets(t *testing.T) {
	d := New(Config{})
	m := d.Find("𠀀𠀀 13800138000")
	if len(m) != 1 || m[0].Start != 5 || m[0].End != 16 {
		t.Fatalf("offsets = %+v", m)
	}
}

func BenchmarkFind(b *testing.B) {
	d := New(Config{Keywords: []string{"张三", "李四"}})
	line := "张三的电话 13800138000，邮箱 zhangsan@example.com，token=sk-abcdefghijklmnopqrstuvwxyz"
	for i := 0; i < b.N; i++ {
		d.Find(line)
	}
}

// 只选了二维码 / 人脸时，界面传 kinds=["keyword"] 且没有关键词：不应匹配任何文字。
func TestKeywordOnlyWithoutWordsMatchesNothing(t *testing.T) {
	d := New(Config{Kinds: []string{KindKeyword}})
	if got := d.Find("手机 13800138000 邮箱 a@b.com"); len(got) != 0 {
		t.Fatalf("expected no matches, got %v", got)
	}
}
