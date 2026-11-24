#!/bin/bash
# SwiftDown 发行包打包脚本
#
# 产出两个文件（放 build/dist/）：
#   SwiftDown-<版本>-<架构>.zip  —— 最简单，解压即用
#   SwiftDown-<版本>-<架构>.dmg  —— 打开后拖进「应用程序」
#
# 为什么两个都给：dmg 安装体验好，zip 便于脚本下载；
# 两者都是 ad-hoc 签名（本机无开发者证书），首次打开需绕过 Gatekeeper，见 README。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 用真实产物路径，不要用 build/SwiftDown.app 这个符号链接：
# ditto 遇到链接会打成「链接」而不是整个 bundle，解压出来是坏的。
APP="$ROOT/build/.dev/SwiftDown.app"
DIST="$ROOT/build/dist"

cd "$ROOT"
# 发行包必须用正式身份（dev.swiftdown.app），不能带 build-app.sh 的开发身份，
# 否则装到「应用程序」里会变成两个不同 id 的 SwiftDown。
SWIFTDOWN_DIST=1 ./Scripts/build-app.sh release

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCH=$(uname -m)
NAME="SwiftDown-${VERSION}-${ARCH}"

mkdir -p "$DIST"
rm -f "$DIST/$NAME.zip" "$DIST/$NAME.dmg"

echo "▶ 打 zip"
# --norsrc：不写 __MACOSX 资源分叉目录（签名在 _CodeSignature 内，不依赖资源分叉），
# 解压出来是干净的 SwiftDown.app。
ditto -c -k --norsrc --keepParent "$APP" "$DIST/$NAME.zip"

echo "▶ 打 dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# UDZO = 只读压缩镜像，体积最小；不做自定义背景，保持零额外依赖
hdiutil create \
  -volname "SwiftDown $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DIST/$NAME.dmg" >/dev/null

echo "✓ 完成："
ls -lh "$DIST" | tail -n +2 | awk '{print "  " $9 "  " $5}'

# 打完包就把开发产物清掉。
#
# 这一步不是洁癖：`build/.dev/SwiftDown.app` 用的是**正式身份**（SWIFTDOWN_DIST=1），
# 和 /Applications 里那份 bundle id 完全一样。只要它还躺在磁盘上，
# LaunchServices 就会把它当成「同一个应用的另一个拷贝」，启动台/聚焦并排出现两个 SwiftDown。
# 之前只在 build-app.sh clean 里清理，导致每次打包完都会多出一份，直到下次 clean 才消失。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$ROOT/build/SwiftDown.app" >/dev/null 2>&1 || true
rm -rf "$APP" "$ROOT/build/SwiftDown.app" 2>/dev/null || true
killall Dock 2>/dev/null || true
echo
echo "  已清理 build/.dev（同身份的副本会让启动台出现两个 SwiftDown）"
echo
echo "  首次打开（未签名提示）可执行："
echo "    xattr -dr com.apple.quarantine \"/Applications/SwiftDown.app\""
