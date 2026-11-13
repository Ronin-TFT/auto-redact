# 自动打码

录屏、共享屏幕时，自动识别并遮住手机号、邮箱、身份证号、银行卡号、API 密钥、密码等敏感信息的 macOS 工具。
全部在本机离线完成，画面不会上传。

## 两种模式

| 模式 | 用途 | 效果 |
|---|---|---|
| **录屏并打码** | 录教程、录演示 | 输出 MP4，**每一帧都已打码**。文字识别每秒几次，两次之间逐帧追踪画面移动，遮挡紧贴文字；画面比实时晚约半秒写入，新识别到的内容会沿缓存的画面往回追踪，补上它之前每一帧（包括刚滚进画面时）的位置。 |
| **屏幕遮挡** | Zoom、腾讯会议等共享屏幕 | 在敏感信息上方盖深色遮挡块，对方和你自己都会看到遮挡。每秒 30 次逐帧追踪画面移动，遮挡块跟着文字走，并按滚动速度提前覆盖；从未识别过的新内容在下一次识别前（约 0.2 秒）仍可能短暂露出。 |

## 能识别的内容

- 手机号（含 `138 0013 8000`、`+86`、国际号码；会纠正 OCR 把 0 认成 O 这类错误）
- 邮箱
- 身份证号（校验出生日期和校验位，避免误伤订单号）
- 银行卡号（Luhn 校验）
- API 密钥 / 令牌：OpenAI、Anthropic、GitHub、AWS、Slack、Google、Stripe、JWT、私钥，以及 `api_key=…`、`token: …` 字段
- 密码 / 验证码：`密码：xxx`、`password = xxx`、`验证码: 123456` 的值
- IP 地址（默认关闭）
- 自定义关键词（人名、公司名、项目代号……；中文关键词需勾选“精确识别”）
- 二维码 / 条形码（默认开启，不依赖文字识别）
- 人脸（默认关闭，遮挡范围比脸略大）

## 隐私与其他功能

- **隐私 App**：选几个 App（微信、邮件、密码管理器……），录屏时它们的窗口不会出现在录像里，遮挡模式下整块盖住，不依赖文字识别。
- **系统通知**：录屏时横幅通知、通知中心不会被录进去；遮挡模式下整块盖住（默认开启）。
- **固定遮挡区域**：框选屏幕上始终要遮住的位置（书签栏、侧边栏……），两种模式都生效。
- **录制范围**：整个屏幕，或框选一块区域（录制时屏幕上用红色虚线标出，不会录进去）。
- **声音**：可同时录系统声音（不含本 App）和麦克风，可选麦克风设备。
- **录完复查**：录完自动打开复查窗口，按打码片段跳转、逐帧检查；漏掉的地方框选后设定起止时间，导出“修正版”。
- **全局快捷键**：⌃⌥⌘R 开始 / 停止录屏，⌃⌥⌘H 开始 / 停止遮挡（App 在后台也能用；被占用时在“快捷键”页提示）。
- **更省电的识别**：画面不变时不重复识别；只有一小块变化时只识别那一块，每秒至少整屏识别一次。按原始分辨率识别，小字更可靠，录像再按所选画质缩放。

识别频率用滑块调节（每秒 1–15 次）。启动时会用一张样例画面实测本机识别一帧的耗时，在滑块旁显示推荐值（识别最多占一半时间，余量留给追踪和录制），点“使用推荐值”即可。

打码样式：马赛克、模糊、色块。开始前可以点 **检查当前屏幕**，只显示找到几处、什么类型，不显示内容。

## 安装与构建

要求 macOS 13+，需要 Go（https://go.dev/dl/）和 Xcode Command Line Tools。

```sh
./build_dmg.sh
open dist/AutoRedact.dmg
```

首次使用需要在 **系统设置 → 隐私与安全性 → 屏幕与系统录音** 中允许“自动打码”，然后重新打开 App。
录麦克风时还需要允许 **麦克风** 权限（第一次勾选时系统会询问）。
使用临时签名时，每次重新打包都需要重新授权。

## 测试

完整的测试步骤和手动测试清单见 [docs/TESTING.md](docs/TESTING.md)，测试数据用 [tests/fixtures/sensitive-sample.txt](tests/fixtures/sensitive-sample.txt)（全部为虚构数据）。

```sh
# 识别规则（任意平台）
go test ./...

# 逐帧追踪：合成滚动画面，逐帧检查是否遮住、遮挡是否贴合（任意平台）
mkdir -p build && cc -O2 -I mac tests/motion_test.c mac/ARMotion.c -lm -o build/motion-test && build/motion-test

# 原生部分：坐标换算、打码渲染，以及用 Vision 真实识别合成图片（macOS）
mkdir -p build && go build -buildmode=c-archive -o build/libredact.a .
clang -fobjc-arc -I build -I mac tests/mac_test.m $(ls mac/*.m | grep -v main.m) mac/ARMotion.c build/libredact.a \
  -framework Cocoa -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework CoreImage -framework Vision -framework CoreFoundation -framework AVKit -framework Carbon -o build/mac-test && build/mac-test
```

## 代码结构

| 路径 | 作用 |
|---|---|
| `internal/detect/` | 敏感信息识别规则（校验位、Luhn、OCR 纠错），返回 UTF-16 范围 |
| `mac/ARMotion.c` | 逐帧追踪（纯 C）：比对相邻画面估算每个打码框的位移（亚像素），新识别结果往回、往前追踪，处理滚入滚出画面、识别漏掉 |
| `bridge.go` | 编译为静态库供 App 调用的 C 接口 |
| `mac/ARCapture.m` | ScreenCaptureKit 屏幕画面（排除本 App 的窗口） |
| `mac/ARRecognizer.m` | Vision 文字识别 → 敏感信息位置 |
| `mac/ARRecordSession.m` | 录屏模式：延迟写入、打码、H.264 MP4 |
| `mac/AROverlaySession.m` | 遮挡模式：遮挡窗口 |
| `mac/ARRedact.m` | 马赛克 / 模糊 / 色块渲染 |
| `mac/ARMicrophone.m` | 麦克风录音 |
| `mac/ARPrivacyWindows.m` | 隐私 App、系统通知的窗口位置 |
| `mac/ARRegionSelector.m` | 框选录制范围、固定遮挡区域 |
| `mac/ARHotkeys.m` | 全局快捷键 |
| `mac/ARReviewController.m`、`mac/ARPatchExporter.m` | 录完复查、手动补打码并导出 |
| `mac/ARAppDelegate.m` | 界面（分页）、菜单栏、设置 |

## 识别不稳定时

小字、浅色字、深色模式下，文字识别可能时有时无。为此：

- 不限制最小文字高度（系统默认会忽略高度小于画面 1/32 的文字）；
- 数字被认错时自动纠正（O→0、l→1、Z→2、S→5、B→8 等，仅限紧挨数字的字母）；
- 已识别到的内容，只要逐帧追踪确认画面没变，就一直保持遮挡，某次没识别到也不会闪；
- 仍然识别不到时，勾选“精确识别”（较慢，推荐频率会自动降低）。

## 限制

- 识别依赖 OCR：字太小、背景复杂、艺术字可能识别不到。重要场合请先录一段检查。
- 中文识别使用精确模式，速度较慢；勾选“精确识别”后推荐频率会按实测速度自动降低。
- 遮挡模式无法预知从未识别过的新内容，可能短暂露出；高度敏感的信息请在共享前关闭。
- 一直停在画面边缘、只露出半截的文字识别不到，也就无法遮住。
