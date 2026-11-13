# 自动打码

录屏、共享屏幕时，自动识别并遮住手机号、邮箱、身份证号、银行卡号、API 密钥、密码等敏感信息的 macOS 工具。
全部在本机离线完成，画面不会上传。

## 两种模式

| 模式 | 用途 | 效果 |
|---|---|---|
| **录屏并打码** | 录教程、录演示 | 输出 MP4，**每一帧都已打码**。画面比实时晚约半秒写入：每帧都等它之后的一次识别完成，再用前后两次识别结果打码，文字移动经过的区域也会遮住。 |
| **屏幕遮挡** | Zoom、腾讯会议等共享屏幕 | 在敏感信息上方盖深色遮挡块，对方和你自己都会看到遮挡。新出现的内容在下一次识别前（约 0.2 秒）可能短暂露出。 |

## 能识别的内容

- 手机号（含 `138 0013 8000`、`+86`、国际号码；会纠正 OCR 把 0 认成 O 这类错误）
- 邮箱
- 身份证号（校验出生日期和校验位，避免误伤订单号）
- 银行卡号（Luhn 校验）
- API 密钥 / 令牌：OpenAI、Anthropic、GitHub、AWS、Slack、Google、Stripe、JWT、私钥，以及 `api_key=…`、`token: …` 字段
- 密码 / 验证码：`密码：xxx`、`password = xxx`、`验证码: 123456` 的值
- IP 地址（默认关闭）
- 自定义关键词（人名、公司名、项目代号……；中文关键词需勾选“识别中文”）

打码样式：马赛克、模糊、色块。开始前可以点 **检查当前屏幕**，只显示找到几处、什么类型，不显示内容。

## 安装与构建

要求 macOS 13+，需要 Go（https://go.dev/dl/）和 Xcode Command Line Tools。

```sh
./build_dmg.sh
open dist/AutoRedact.dmg
```

首次使用需要在 **系统设置 → 隐私与安全性 → 屏幕与系统录音** 中允许“自动打码”，然后重新打开 App。
使用临时签名时，每次重新打包都需要重新授权。

## 测试

完整的测试步骤和手动测试清单见 [docs/TESTING.md](docs/TESTING.md)，测试数据用 [tests/fixtures/sensitive-sample.txt](tests/fixtures/sensitive-sample.txt)（全部为虚构数据）。

```sh
# 识别规则与跟踪逻辑（任意平台）
go test ./...

# 原生部分：坐标换算、打码渲染，以及用 Vision 真实识别合成图片（macOS）
mkdir -p build && go build -buildmode=c-archive -o build/libredact.a .
clang -fobjc-arc -I build -I mac tests/mac_test.m $(ls mac/*.m | grep -v main.m) build/libredact.a \
  -framework Cocoa -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework CoreImage -framework Vision -framework CoreFoundation -o build/mac-test && build/mac-test
```

## 代码结构

| 路径 | 作用 |
|---|---|
| `internal/detect/` | 敏感信息识别规则（校验位、Luhn、OCR 纠错），返回 UTF-16 范围 |
| `internal/track/` | 根据定期识别结果计算每一帧的打码区域（前后结果并集、移动范围、保留时间） |
| `bridge.go` | 编译为静态库供 App 调用的 C 接口 |
| `mac/ARCapture.m` | ScreenCaptureKit 屏幕画面（排除本 App 的窗口） |
| `mac/ARRecognizer.m` | Vision 文字识别 → 敏感信息位置 |
| `mac/ARRecordSession.m` | 录屏模式：延迟写入、打码、H.264 MP4 |
| `mac/AROverlaySession.m` | 遮挡模式：遮挡窗口 |
| `mac/ARRedact.m` | 马赛克 / 模糊 / 色块渲染 |
| `mac/ARAppDelegate.m` | 界面、菜单栏、设置 |

## 限制

- 识别依赖 OCR：字太小、背景复杂、艺术字可能识别不到。重要场合请先录一段检查。
- 中文识别使用精确模式，速度较慢，建议识别频率选每秒 3 次。
- 遮挡模式无法预知下一帧，新内容可能短暂露出；高度敏感的信息请在共享前关闭。
