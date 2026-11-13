#!/bin/zsh
# 构建“自动打码”通用版（Apple Silicon + Intel）App 与 DMG。需要 Go 与 Xcode Command Line Tools。
# 用法：./build_dmg.sh            临时签名
#       SIGN_IDENTITY="证书名" ./build_dmg.sh   使用自己的代码签名证书
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
NAME="自动打码"
APP="$ROOT/dist/$NAME.app"
DMG="$ROOT/dist/AutoRedact.dmg"
BUILD="$ROOT/build"
export MACOSX_DEPLOYMENT_TARGET=13.0
GO="${GO:-$(command -v go || true)}"
if [[ -z "$GO" ]]; then
  echo "需要安装 Go：https://go.dev/dl/" >&2
  exit 1
fi

rm -rf "$APP" "$DMG" "$BUILD/lib" "$BUILD/dmg" "$BUILD/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/lib" "$BUILD/AppIcon.iconset"

# 识别与跟踪引擎：分别编译两种架构的静态库，再合并。
for goarch clangarch in arm64 arm64 amd64 x86_64; do
  CGO_ENABLED=1 GOOS=darwin GOARCH=$goarch \
    CC="clang -arch $clangarch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    "$GO" build -buildmode=c-archive -trimpath -o "$BUILD/lib/$goarch/libredact.a" .
done
lipo -create "$BUILD/lib/arm64/libredact.a" "$BUILD/lib/amd64/libredact.a" -output "$BUILD/lib/libredact.a"
cp "$BUILD/lib/arm64/libredact.h" "$BUILD/lib/libredact.h"

clang -arch arm64 -arch x86_64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -fobjc-arc -O2 -Wall \
  -I "$BUILD/lib" mac/*.m mac/*.c "$BUILD/lib/libredact.a" -o "$APP/Contents/MacOS/AutoRedact" \
  -framework Cocoa -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework CoreImage -framework Vision -framework CoreFoundation -framework AVKit -framework Carbon
lipo -info "$APP/Contents/MacOS/AutoRedact"
cp mac/Info.plist "$APP/Contents/Info.plist"

clang -fobjc-arc tools/make_icon.m -framework Cocoa -o "$BUILD/make_icon"
"$BUILD/make_icon" "$BUILD/icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  echo "提示：未设置 SIGN_IDENTITY，使用临时签名；每次重新打包后需要重新授予屏幕录制权限。" >&2
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier local.ronin.autoredact "$APP"
codesign --verify --strict "$APP"

mkdir -p "$BUILD/dmg"
ditto "$APP" "$BUILD/dmg/$NAME.app"
ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -volname "$NAME" -srcfolder "$BUILD/dmg" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
