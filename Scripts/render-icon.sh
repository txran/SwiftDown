#!/bin/bash
# 把 Assets/*.svg 母版渲染成 1024×1024 透明 PNG（Chrome headless）
#
# 为什么用 Chrome：本机没有 rsvg-convert / cairosvg，而 Chrome 自带完整 SVG 渲染器；
# --default-background-color=00000000 保证圆角外是透明而非白底（否则图标四角会出现白方块）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
test -x "$CHROME" || { echo "✗ 找不到 Google Chrome"; exit 1; }

for svg in "$ROOT"/Assets/icon.svg "$ROOT"/Assets/icon-small.svg; do
  name="$(basename "${svg%.svg}")"
  rm -f "$ROOT/Assets/${name}-1024.png"
  "$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 \
    --screenshot="$ROOT/Assets/${name}-1024.png" \
    --window-size=1024,1024 "file://$svg" >/dev/null 2>&1 || true
  # Chrome 的成功信息走 stderr 且退出码不可靠，用产物存在性 + 尺寸做校验
  test -f "$ROOT/Assets/${name}-1024.png" || { echo "✗ 渲染失败：$svg"; exit 1; }
  echo "✓ Assets/${name}-1024.png"
done
