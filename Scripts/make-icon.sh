#!/bin/bash
# SwiftDown 图标打包：两套 1024 母版 → .iconset → AppIcon.icns
#
# 为什么手写而不用 Asset Catalog：本机只有 Command Line Tools（无 Xcode），
# 无法编译 Assets.car，所以走 iconutil 的传统 .icns 路线，Info.plist 用 CFBundleIconFile 指向它。
#
# 为什么分两套母版：16/32/64 直接用完整稿缩放会把正文条和投影糊成一团，
# 小尺寸改用精简稿（笔画加粗、正文条减到 2 条、箭头放大），这是 macOS 系统图标的通行做法。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FULL="$ROOT/Assets/icon-1024.png"
SMALL="$ROOT/Assets/icon-small-1024.png"
SET="$ROOT/Assets/AppIcon.iconset"
OUT="$ROOT/Assets/AppIcon.icns"

for f in "$FULL" "$SMALL"; do
  test -f "$f" || { echo "✗ 缺少母版 $f（先跑 make-icon.py 并用 Chrome 渲染）"; exit 1; }
done

rm -rf "$SET"; mkdir -p "$SET"

# 尺寸 | iconset 名 | 用哪套母版
while read -r px name master; do
  sips -z "$px" "$px" "$master" --out "$SET/icon_${name}.png" >/dev/null
done <<EOF
16 16x16 $SMALL
32 16x16@2x $SMALL
32 32x32 $SMALL
64 32x32@2x $SMALL
128 128x128 $FULL
256 128x128@2x $FULL
256 256x256 $FULL
512 256x256@2x $FULL
512 512x512 $FULL
1024 512x512@2x $FULL
EOF

iconutil -c icns "$SET" -o "$OUT"
echo "✓ $OUT"
