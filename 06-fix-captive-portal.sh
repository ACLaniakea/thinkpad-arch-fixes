#!/bin/bash
# =============================================================================
# 06-fix-captive-portal.sh — 强制门户（需要登录的 WiFi）登录页修复
# ThinkPad X13 Gen 4 · Arch Linux · KDE Plasma 6
#
# 症状：连上需要登录的 WiFi 后，浏览器反复被重定向到"连通性测试网站"，
#       真正的登录页打不开（多数门户只劫持 HTTP 80 端口）。
#
# 方案：
#   1) 确保 NetworkManager 连通性检查 URI 配置正常（Arch 默认 ping.archlinux.org）
#   2) 安装 open-captive-portal 助手：一键打开门户登录页
#      （优先访问网关 IP，其次纯 HTTP 站 neverssl.com 触发门户劫持）
#
# 用法：sudo bash 06-fix-captive-portal.sh
# 依赖：networkmanager、xdg-utils
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo bash $0" >&2; exit 1; }
for cmd in nmcli ip xdg-open; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[错误] 缺少命令：$cmd" >&2; exit 1; }
done
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

echo "[1/3] 确保 NetworkManager 连通性检查配置正常"
URI=""
if [ -f /etc/NetworkManager/conf.d/20-connectivity.conf ]; then
    URI=$(grep -E '^uri=' /etc/NetworkManager/conf.d/20-connectivity.conf 2>/dev/null | cut -d= -f2- || true)
fi
if [ -n "$URI" ]; then
    echo "  现有 URI: $URI"
else
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/20-connectivity.conf <<'EOF'
[connectivity]
uri=http://ping.archlinux.org/nm-check.txt
EOF
    echo "  已写入默认 URI: http://ping.archlinux.org/nm-check.txt"
fi
nmcli general reload >/dev/null 2>&1 || \
    echo "  [!] NetworkManager 配置尚未立即 reload，重启 NetworkManager 后生效。" >&2

echo "[2/3] 安装 open-captive-portal 助手"
cat > /usr/local/bin/open-captive-portal <<'HELPER'
#!/bin/sh
# 打开强制门户登录页：优先网关 IP，再补一个纯 HTTP 站点触发门户劫持。
# 用法：open-captive-portal
gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
if [ -n "$gw" ]; then
    xdg-open "http://$gw" >/dev/null 2>&1 &
fi
sleep 1
xdg-open "http://neverssl.com" >/dev/null 2>&1 &
HELPER
chmod 755 /usr/local/bin/open-captive-portal

echo "[3/3] 验证"
echo "  连通性 URI: $(grep -E '^uri=' /etc/NetworkManager/conf.d/20-connectivity.conf 2>/dev/null | cut -d= -f2- || echo 无)"
echo "  助手: /usr/local/bin/open-captive-portal"
echo
echo "使用方法："
echo "  1) 连上需要登录的 WiFi 后，在终端运行: open-captive-portal"
echo "     （会自动打开网关 IP / neverssl.com，多半能弹出真正的登录页）"
echo "  2) 查看门户状态: nmcli -t -f CONNECTIVITY general   （portal=需要登录）"
echo "  3) KDE 弹『检测到强制门户』通知时，点击它也能打开登录页"
echo "  4) 如果某门户登录页强制 HTTPS 且证书异常，用浏览器无痕窗口访问网关 IP"
