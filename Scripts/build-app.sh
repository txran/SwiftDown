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
# 产物放在 build/.dev/ 这个隐藏目录里。
#
# 为什么藏在点上：macOS 的「应用程序」（Spotlight 驱动的应用列表）会收录任何被索引的
# .app bundle，但跳过以 . 开头的目录。开发产物若直接躺在 build/ 下，就会和
# /Applications 里装好的那份并排出现成两个图标；放进隐藏目录后两者不再重复。
# 对外的便捷路径 build/SwiftDown.app 保留为符号链接（符号链接同样不被索引）。
APP="$ROOT/build/.dev/SwiftDown.app"
APP_LINK="$ROOT/build/SwiftDown.app"
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

# 开发构建用独立身份，避免与已安装的发行版撞车。
#
# 为什么必须分开：两个 .app bundle 共用同一个 CFBundleIdentifier 时，LaunchServices 认为
# 它们是「同一个应用的两份」，于是「应用程序」里出现两个同名同图标的入口、⌘Tab 里出现两个
# 同款图标、「打开方式」指向哪一份不确定（Spotlight 命中的往往是项目里那份）。
#
# 发行打包由 package-app.sh 传 SWIFTDOWN_DIST=1，保持正式身份（dev.swiftdown.app）。
if [ "${SWIFTDOWN_DIST:-0}" != "1" ]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier dev.swiftdown.app.dev" \
    -c "Set :CFBundleName SwiftDown Dev" \
    -c "Set :CFBundleDisplayName SwiftDown Dev" \
    "$APP/Contents/Info.plist"
  echo "  ℹ 开发身份：SwiftDown Dev（dev.swiftdown.app.dev），与 /Applications 里的正式版互不干扰"
fi

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

# 便捷入口：build/SwiftDown.app 指向隐藏目录里的真实产物。
# 若历史上这里是真实目录（旧版脚本直接建在这里），先清掉再建链接。
if [ -e "$APP_LINK" ] && [ ! -L "$APP_LINK" ]; then
  rm -rf "$APP_LINK"
fi
ln -sfn ".dev/SwiftDown.app" "$APP_LINK"

echo "✓ 完成：$APP"
echo "  快捷路径：${APP_LINK}（符号链接，不进 Spotlight）"
echo "  启动：open \"$APP\""
echo "  自检：\"$APP/Contents/MacOS/SwiftDown\" --selftest <某个.md文件>"
