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
# 为什么藏在点上：磁盘上只要存在第二份 .app，LaunchServices 就会把它认成「同一个应用的
# 另一个拷贝」，启动台/聚焦里并排出现两个图标——与 /Applications 里有几个文件无关。
# 但仅靠隐藏目录不够：实测 build/SwiftDown.app 这个符号链接会把内容暴露回索引，
# 于是「SwiftDown Dev」仍然出现在启动台里。所以收尾要双保险（见脚本末尾）：
#   1. 在 build/ 与 build/.dev/ 放 .metadata_never_index，让 Spotlight 跳过整棵树；
#   2. lsregister -u 注销开发版的应用注册。
# 注销只影响「按名字找应用」，`open -a <绝对路径>` 与直接执行二进制都不受影响。
APP="$ROOT/build/.dev/SwiftDown.app"
APP_LINK="$ROOT/build/SwiftDown.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 清理开发产物。
#
# 为什么必须能清：只要 SwiftDown.app 这个 bundle 还躺在磁盘上，mds 扫描一次就会把它
# 重新注册进 LaunchServices，启动台/聚焦里立刻多出一个「SwiftDown Dev」——
# `.metadata_never_index` 拦不住已经建立过索引的目录，`lsregister -u` 也会在几十秒内被回填。
# 实测唯一稳的做法是让磁盘上不再有第二份 bundle。
if [ "$CONFIG" = "clean" ]; then
    echo "▶ 清理开发产物"
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$APP_LINK" >/dev/null 2>&1 || true
    rm -rf "$APP" "${APP}.dSYM" 2>/dev/null || true
    rm -f "$APP_LINK" 2>/dev/null || true
    killall Dock 2>/dev/null && echo "  Dock 已重启"
    echo "✓ 已删除 $APP 并注销注册"
    echo "  系统里现在只剩 /Applications/SwiftDown.app"
    exit 0
fi
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

# 不让开发版出现在启动台 / 聚焦（见文件头注释）。
# .metadata_never_index 是 Spotlight 的目录级排除标记，放在 build/ 与 build/.dev/ 各一份。
touch "$ROOT/build/.metadata_never_index"
touch "$ROOT/build/.dev/.metadata_never_index"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$APP_LINK" >/dev/null 2>&1 || true

echo "✓ 完成：$APP"
echo "  快捷路径：${APP_LINK}（符号链接；已排除 Spotlight 索引并注销 LS 注册，不进启动台）"
echo "  启动：open \"$APP\""
echo "  自检：\"$APP/Contents/MacOS/SwiftDown\" --selftest <某个.md文件>"
