#!/bin/bash
# 运行单元测试。
#
# 背景：本仓库使用 Swift Testing。装有完整 Xcode 的机器上 `swift test` 开箱即用；
# 只有 Command Line Tools 的机器上，SwiftPM 不会自动定位 CLT 自带的 Testing.framework，
# 且 CLT 的 _Testing_Foundation 缺少 swiftmodule，需要额外传参绕过（不影响任何逻辑）。
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

if [ -d "/Applications/Xcode.app" ] || xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    exec swift test "$@"
fi

if [ ! -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    echo "未找到 Testing.framework，请安装 Xcode 或 Command Line Tools。" >&2
    exit 1
fi

# 新版 CLT 的 Testing.framework 还依赖 lib_TestingInterop.dylib（在 Library/Developer/usr/lib）。
CLT_TESTING_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
EXTRA_RPATH=()
if [ -d "$CLT_TESTING_LIB" ]; then
    EXTRA_RPATH=(-Xlinker -rpath -Xlinker "$CLT_TESTING_LIB")
fi

exec swift test \
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
    "${EXTRA_RPATH[@]}" \
    "$@"
