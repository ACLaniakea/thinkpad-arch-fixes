#!/bin/bash
# =============================================================================
# 05-fix-kioworker-calligra.sh — 修复 kioworker (Dolphin 缩略图) 反复崩溃
# ThinkPad X13 Gen 4 · Arch Linux · KDE Plasma 6
#
# 背景：Dolphin 为 Calligra 文档(.doc/.docx/.odt 等)生成缩略图时，Calligra 的
#       doc→odt 转换过滤器(calligra_filter_doc2odt.so)段错误，kioworker 崩溃弹窗。
# 修复：在 KDE 预览设置中禁用 calligrathumbnail 插件（不卸载 Calligra，可还原）。
# 可选：--uninstall-calligra 彻底卸载 Calligra（当无包依赖且不使用它时）。
#
# 用法：sudo bash 05-fix-kioworker-calligra.sh [--uninstall-calligra]
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo bash $0" >&2; exit 1; }
TARGET_USER=${SUDO_USER:-}
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    TARGET_USER=$(getent passwd 1000 | cut -d: -f1)
fi
[ -n "$TARGET_USER" ] || { echo "[!] 找不到桌面用户" >&2; exit 1; }
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

as_user() {
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
        XDG_RUNTIME_DIR="/run/user/$TARGET_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
        "$@"
}

if [ "${1:-}" = "--uninstall-calligra" ]; then
    echo "[*] 彻底卸载 Calligra（含导致崩溃的缩略图插件）"
    pacman -Rns calligra
    echo "完成。"
    exit 0
fi

DIR=/usr/lib/qt6/plugins/kf6/thumbcreator
if [ ! -d "$DIR" ]; then
    echo "[!] 未找到缩略图插件目录，可能不是 KDE Plasma 6，跳过"
    exit 0
fi

echo "[1/2] 禁用 calligrathumbnail（动态保留其余全部插件）"
CUR=$(as_user kreadconfig6 --file kdeglobals --group PreviewSettings --key Plugins 2>/dev/null || true)
if [ -n "$CUR" ] && ! printf '%s' "$CUR" | tr ',' '\n' | grep -qx 'calligrathumbnail'; then
    echo "  已处于禁用状态，跳过"
else
    if [ -n "$CUR" ]; then
        # 保留用户现有的插件选择，只移除 calligrathumbnail。
        LIST=$(printf '%s' "$CUR" | awk -F, '{ for (i = 1; i <= NF; i++) if ($i != "" && $i != "calligrathumbnail") { if (n++) printf ","; printf "%s", $i } }')
    else
        LIST=$(find "$DIR" -maxdepth 1 -type f -name '*.so' -printf '%f\n' | sed 's/\.so$//' | awk '$0 != "calligrathumbnail" { if (n++) printf ","; printf "%s", $0 }')
    fi
    as_user kwriteconfig6 --file kdeglobals --group PreviewSettings --key Plugins "$LIST"
    echo "  已写入插件列表：$(printf '%s' "$LIST" | tr ',' '\n' | wc -l) 个（不含 calligrathumbnail）"
fi

echo "[2/2] 清理残留缩略图 worker 与崩溃弹窗"
for pid in $(pgrep -f '/usr/lib/kf6/kioworker.*thumbnail' 2>/dev/null || true); do
    [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null || true
done
for pid in $(pgrep -f 'drkonqi.*--appname kioworker' 2>/dev/null || true); do
    [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null || true
done
sleep 1
echo
echo "完成！Dolphin 不再用 Calligra 生成缩略图，崩溃弹窗将不再出现。"
echo "彻底卸载 Calligra（无依赖且不使用它时）：sudo bash $0 --uninstall-calligra"
