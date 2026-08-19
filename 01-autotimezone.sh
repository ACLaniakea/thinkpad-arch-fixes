#!/bin/bash
# =============================================================================
# 01-autotimezone.sh — KDE 自动时区（IP 定位）· ThinkPad X13 Gen 4 · Arch Linux
#
# 1) 启用 KDE geotimezoned（plasma-workspace 自带，按 geoip.kde.org 切时区）
#    + polkit 规则免密 set-timezone
# 2) ipinfo/ipwhois 兜底更新器（HTTP/SOCKS 代理可绕过；TUN/VPN 出口则跳过）
# 3) 启用 NTP（systemd-timesyncd 优先，停用 ntpd 避免冲突）
#
# 中国全境统一北京时间：ipinfo 对新疆返回 Asia/Urumqi，映射回 Asia/Shanghai
#
# 用法：sudo bash 01-autotimezone.sh
# 依赖：plasma-workspace、qt6-tools(qdbus6)、polkit、curl、networkmanager、systemd
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo bash $0" >&2; exit 1; }
for cmd in curl ip timedatectl; do
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

echo "[1/4] 启用 KDE geotimezoned + polkit 免密授权"
RULE=/etc/polkit-1/rules.d/99-kde-autotimezone.rules
mkdir -p /etc/polkit-1/rules.d
cat > "$RULE" <<EOF
// Allow $TARGET_USER to change the system timezone without a password.
// Required by KDE Plasma's geotimezoned (automatic timezone by location).
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.timedate1.set-timezone" &&
        subject.user == "$TARGET_USER") {
        return polkit.Result.YES;
    }
});
EOF
chmod 644 "$RULE"
as_user qdbus6 org.kde.kded6 /kded setModuleAutoloading geotimezoned true >/dev/null 2>&1 || echo "  [!] 无桌面会话，登录 KDE 后 geotimezoned 自动生效"
as_user qdbus6 org.kde.kded6 /kded loadModule geotimezoned >/dev/null 2>&1 || true

echo "[2/4] 安装 IP 时区兜底更新器"
cat > /usr/local/bin/update-system-timezone.sh <<'TZ'
#!/bin/bash
# 按出口 IP 获取时区并设置。
# 代理处理：HTTP/SOCKS 代理由 direct_curl 绕过；TUN/VPN 出口跳过更新避免污染。
# 分流放行：touch /etc/thinkpad-fixes.allow-proxy-location
# 中国全境统一北京时间：ipinfo 对新疆返回 Asia/Urumqi，映射回 Asia/Shanghai
set -u

direct_curl() {
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        curl --noproxy '*' --max-time 10 -fsS "$@"
}

# 网络层隧道检测：公网出口走 TUN/TAP/WireGuard 时出口 IP 已被改写，无法绕过
if [ ! -f /etc/thinkpad-fixes.allow-proxy-location ] \
   && ip route get 8.8.8.8 2>/dev/null | grep -qE "dev (tun|tap|wg)[0-9]"; then
    echo "[$(date '+%F %T')] 检测到 TUN/VPN 出口，跳过 IP 定位更新（放行：touch /etc/thinkpad-fixes.allow-proxy-location）" >&2
    exit 0
fi

zone=""
for url in https://ipinfo.io/json https://ipwho.is/; do
    json=$(direct_curl "$url") || continue
    if command -v jq >/dev/null 2>&1; then
        zone=$(printf '%s' "$json" | jq -r '.timezone // empty')
    else
        zone=$(printf '%s' "$json" | sed -nE 's/.*"timezone"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._+\/-]+)".*/\1/p')
    fi
    [ -n "$zone" ] && [ "$zone" != "null" ] && break
done
[ -n "$zone" ] || exit 0
case "$zone" in */*) ;; *) exit 0 ;; esac
[ "$zone" = "Asia/Urumqi" ] && zone="Asia/Shanghai"
[ -f "/usr/share/zoneinfo/$zone" ] || exit 0
current=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
if [ "$current" != "$zone" ]; then
    timedatectl set-timezone "$zone" >/dev/null 2>&1 || \
        echo "[$(date '+%F %T')] 设置时区失败：$zone" >&2
fi
TZ
chmod 755 /usr/local/bin/update-system-timezone.sh

cat > /etc/NetworkManager/dispatcher.d/60-update-system-timezone <<'DISP'
#!/bin/sh
[ "${2:-}" = up ] || exit 0
/usr/local/bin/update-system-timezone.sh >/dev/null 2>&1 || true
DISP
chmod 755 /etc/NetworkManager/dispatcher.d/60-update-system-timezone

cat > /etc/systemd/system/update-system-timezone.service <<'UNIT'
[Unit]
Description=Refresh system timezone from current network location
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-system-timezone.sh
UNIT
cat > /etc/systemd/system/update-system-timezone.timer <<'UNIT'
[Unit]
Description=Refresh system timezone periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now update-system-timezone.timer >/dev/null

echo "[3/4] 启用 NTP（systemd-timesyncd 优先，停掉冲突的 ntpd）"
if systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
    systemctl unmask systemd-timesyncd.service >/dev/null 2>&1 || true
    systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true
    timedatectl set-ntp true >/dev/null 2>&1 || true
    systemctl disable --now ntpd.service >/dev/null 2>&1 || true
else
    systemctl enable --now ntpd.service >/dev/null 2>&1 || true
    systemctl disable --now systemd-timesyncd.service >/dev/null 2>&1 || true
fi

echo "[4/4] 立即刷新一次并验证"
/usr/local/bin/update-system-timezone.sh || true
echo "  当前时区: $(timedatectl show --property=Timezone --value 2>/dev/null || readlink /etc/localtime)"
echo
echo "完成！说明："
echo "  - KDE geotimezoned 按 geoip.kde.org 切换；代理需让 geoip.kde.org 走直连"
echo "  - 兜底更新器用 ipinfo/ipwhois，联网后 30 分钟内必刷新"
echo "  - 验证: timedatectl / readlink /etc/localtime"
