#!/bin/bash
# 构建 release 二进制并手工组装 WeChatMover.app，最后 ad-hoc 签名。
# 双架构（arm64 + x86_64）通用包：Apple 芯片与 Intel Mac 均可运行。
# CLT 无 XCBuild，SwiftPM 无法一次出多架构产物，故分架构构建后用 lipo 合并。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release --arch arm64"
swift build -c release --arch arm64
echo "==> swift build -c release --arch x86_64"
swift build -c release --arch x86_64

ARM_BIN=".build/arm64-apple-macosx/release/WeChatMover"
X86_BIN=".build/x86_64-apple-macosx/release/WeChatMover"
mkdir -p build
echo "==> lipo 合并为通用二进制"
lipo -create "$ARM_BIN" "$X86_BIN" -output "build/WeChatMover-universal"
lipo -info "build/WeChatMover-universal"

APP="build/WeChatMover.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/WeChatMover-universal" "$APP/Contents/MacOS/WeChatMover"
rm "build/WeChatMover-universal"   # 中间产物，并入 .app 后删除
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "Resources/GitHub-Mark.png" "$APP/Contents/Resources/GitHub-Mark.png"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo "✅ 完成: $APP"
