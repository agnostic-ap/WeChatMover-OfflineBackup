#!/bin/bash
# 重新生成应用图标 Resources/AppIcon.icns。
# 无第三方依赖：Swift/AppKit 离屏绘制 iconset + 系统自带 iconutil 打包。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> 绘制 iconset"
swift Scripts/make_icon.swift

echo "==> iconutil 打包 icns"
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

echo "✅ 完成: Resources/AppIcon.icns"
