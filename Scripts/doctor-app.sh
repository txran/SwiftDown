#!/bin/bash
# doctor-app.sh — 检查/修复 SwiftDown 应用身份冲突（「应用程序里出现两个图标」）
#
# 用法：
#   ./Scripts/doctor-app.sh          只体检，不改任何东西
#   ./Scripts/doctor-app.sh --fix    注销游离副本的 LaunchServices 注册，并删除 /private/tmp 下的测试副本
#
# 判据：LaunchServices 按 CFBundleIdentifier 认身份。只要磁盘上存在第二份 bundle id
# 相同的 .app（哪怕是 /tmp 里的临时副本），系统就会认为它是同一个应用的另一个拷贝，
# Launchpad / 聚焦 里就会出现多个同名图标。所以正式版必须唯一，开发版必须换 id 且放在隐藏目录。

set -uo pipefail

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APPLICATIONS_APP=/Applications/SwiftDown.app
DEV_APP="$ROOT/build/.dev/SwiftDown.app"

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || echo "?"
}

bundle_ver() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo "?"
}

echo "== 1. 正式版 =="
if [ -d "$APPLICATIONS_APP" ]; then
    echo "   $APPLICATIONS_APP  id=$(bundle_id "$APPLICATIONS_APP")  v=$(bundle_ver "$APPLICATIONS_APP")"
else
    echo "   ⚠️  /Applications 下没有 SwiftDown.app"
fi

echo "== 2. 开发版 =="
if [ -d "$DEV_APP" ]; then
    dev_id=$(bundle_id "$DEV_APP")
    echo "   $DEV_APP  id=$dev_id  v=$(bundle_ver "$DEV_APP")"
    if [ "$dev_id" = "$(bundle_id "$APPLICATIONS_APP")" ]; then
        echo "   ⚠️  开发版与正式版 bundle id 相同 —— 必然出现两个图标"
    fi
else
    echo "   （未构建）"
fi

echo "== 3. 扫描游离副本 =="
# LaunchServices 里所有 SwiftDown 相关路径
$LSREG -dump 2>/dev/null \
    | grep -E "^\s*path:\s+/.*[Ss]wift[Dd]own[^/]*\.app" \
    | sed 's/^[[:space:]]*path:[[:space:]]*//; s/ (0x[0-9a-f]*)[[:space:]]*$//' \
    | sort -u > /tmp/doctor-swiftdown-paths.txt

stray=0
while IFS= read -r p; do
    case "$p" in
        "$APPLICATIONS_APP"|"$DEV_APP") continue ;;
    esac
    stray=$((stray + 1))
    if [ -e "$p" ]; then
        echo "   ✗ 存活  id=$(bundle_id "$p")  v=$(bundle_ver "$p")  $p"
    else
        echo "   · 残留注册（文件已不存在）  $p"
    fi
    if [ "$FIX" = "1" ]; then
        $LSREG -u "$p" 2>/dev/null
        case "$p" in
            /private/tmp/*|/tmp/*)
                # 只删临时目录里的测试产物；废纸篓等用户自有位置一律不动
                rm -rf "$p" 2>/dev/null && echo "     → 已注销并删除临时副本"
                ;;
            *)
                echo "     → 已注销注册（文件保留，需要你自行确认是否删除）"
                ;;
        esac
    fi
done < /tmp/doctor-swiftdown-paths.txt

[ "$stray" = "0" ] && echo "   ✓ 没有游离副本"
rm -f /tmp/doctor-swiftdown-paths.txt

if [ "$FIX" = "1" ]; then
    echo "== 4. 重新注册正式版并刷新 Dock =="
    [ -d "$APPLICATIONS_APP" ] && $LSREG -f "$APPLICATIONS_APP" && echo "   已重注册 $APPLICATIONS_APP"
    killall Dock 2>/dev/null && echo "   Dock 已重启（刷新 Launchpad 缓存）"
fi

echo "== 完成 =="
[ "$FIX" = "0" ] && [ "$stray" != "0" ] && echo "提示：加 --fix 可自动清理"
exit 0
