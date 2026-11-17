#!/bin/bash
# SwiftDown .app 打包脚本
#
# 为什么需要它：本机只有 Command Line Tools（无完整 Xcode），
# 无法用 xcodebuild 生成 app bundle，因此用 SPM 编译可执行文件后手工组装 .app。
# 产物与 Xcode 生成的差异仅在「无代码资源目录（Assets.car，图标改走传统 .icns）」与「ad-hoc 签名」，
# 对内部自签分发（PRD §十一）已经够用。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/SwiftDownApp"
CONFIG="${1:-release}"
APP="$ROOT/build/SwiftDown.app"
PLUGIN_PATH="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

echo "▶ 编译 ($CONFIG)..."
swift build \
  --disable-sandbox \
  -c "$CONFIG" \
  --package-path "$PKG" \
  -Xswiftc -plugin-path -Xswiftc "$PLUGIN_PATH"

BIN_DIR="$(swift build --disable-sandbox -c "$CONFIG" --package-path "$PKG" --show-bin-path)"
BIN="$BIN_DIR/SwiftDown"
test -x "$BIN" || { echo "✗ 找不到可执行文件：$BIN"; exit 1; }

echo "▶ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SwiftDown"
cp "$PKG/AppBundle/Info.plist" "$APP/Contents/Info.plist"

# 应用图标：传统 .icns（Info.plist 的 CFBundleIconFile 指向 AppIcon）
ICON="$ROOT/Assets/AppIcon.icns"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  ⚠ 缺少 $ICON —— 本次产物无图标"
  echo "    生成方式：python3 Scripts/make-icon.py && Scripts/render-icon.sh && Scripts/make-icon.sh"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶ ad-hoc 签名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   （签名失败，仍可本地运行）"

echo "✓ 完成：$APP"
echo "  启动：open \"$APP\""
echo "  自检：\"$APP/Contents/MacOS/SwiftDown\" --selftest <某个.md文件>"
