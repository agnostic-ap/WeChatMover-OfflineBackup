#!/bin/bash
# 构建 release 二进制并手工组装 WeChatMover.app，最后 ad-hoc 签名。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP="build/WeChatMover.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/WeChatMover" "$APP/Contents/MacOS/WeChatMover"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo "✅ 完成: $APP"
