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
APP="$ROOT/build/SwiftDown.app"
DIST="$ROOT/build/dist"

cd "$ROOT"
./Scripts/build-app.sh release

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
echo
echo "  首次打开（未签名提示）可执行："
echo "    xattr -dr com.apple.quarantine \"/Applications/SwiftDown.app\""
