#!/bin/bash
# =============================================================================
# 04-autodaynight.sh — 启用 KDE 自动黑白（Day-Night Cycle 自动定位）
# ThinkPad X13 Gen 4 · Arch Linux · KDE Plasma 6
#
# 无 GPS/蜂窝时，WiFi 众包库与 geoclue 自带 IP 库可能不准；本方案用 ipinfo
# （按出口 IP，实测较准）查坐标 → 写 /etc/geolocation → geoclue 静态源实时读取
# → KDE knighttimed 计算日出日落。
#
# 代理处理：HTTP/SOCKS 代理由 direct_curl 绕过；TUN/VPN 出口（无法绕过）则跳过更新。
#
# 用法：sudo bash 04-autodaynight.sh
# 依赖：geoclue、curl、networkmanager、systemd、qt6-positioning(已装)
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo bash $0" >&2; exit 1; }
for cmd in curl ip mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[错误] 缺少命令：$cmd" >&2; exit 1; }
done

echo "[1/6] 安装 geoclue"
pacman -Q geoclue >/dev/null 2>&1 || pacman -S --needed --noconfirm geoclue

echo "[2/6] 写 geoclue 配置：static-source 生效，关闭不可靠的 wifi/ip 源"
mkdir -p /etc/geoclue
[ -f /etc/geoclue/geoclue.conf ] && cp /etc/geoclue/geoclue.conf /etc/geoclue/geoclue.conf.bak.$(date +%s)
cat > /etc/geoclue/geoclue.conf <<'GEOF'
[agent]
whitelist=geoclue-demo-agent

[static-source]
enable=true

[wifi]
enable=false

[ip]
enable=false

[3g]
enable=false

[cdma]
enable=false

[modem-gps]
enable=false

[knighttimed]
allowed=true
system=false
users=

[org.kde.knighttimed]
allowed=true
system=false
users=

[plasmashell]
allowed=true
system=false
users=

[org.kde.plasmashell]
allowed=true
system=false
users=

[kwin_wayland]
allowed=true
system=false
users=

[org.kde.KWin]
allowed=true
system=false
users=
GEOF

echo "[3/6] 修复冷激活丢消息：geoclue 常驻(-t 0) + 开机自启"
mkdir -p /etc/systemd/system/geoclue.service.d
cat > /etc/systemd/system/geoclue.service.d/override.conf <<'OEOF'
[Service]
ExecStart=
ExecStart=/usr/lib/geoclue -t 0

[Install]
WantedBy=multi-user.target
OEOF
systemctl daemon-reload
systemctl enable --now geoclue.service >/dev/null 2>&1 || true

echo "[4/6] 安装 ipinfo → /etc/geolocation 更新器（联网/定时触发）"
cat > /usr/local/bin/update-geolocation.sh <<'UEOF'
#!/bin/bash
# 用 ipinfo 查询经纬度写入 /etc/geolocation（geoclue 静态源实时读取）。
# 代理处理：HTTP/SOCKS 代理由 direct_curl 绕过；TUN/VPN 出口跳过更新避免污染。
# 分流放行：touch /etc/thinkpad-fixes.allow-proxy-location
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

loc=""
for url in https://ipinfo.io/json https://ipwho.is/; do
    json=$(direct_curl "$url") || continue
    if command -v jq >/dev/null 2>&1; then
        loc=$(printf '%s' "$json" | jq -r '.loc // empty')
        [ -n "$loc" ] || loc=$(printf '%s' "$json" | jq -r '[.latitude,.longitude] | map(tostring) | join(",") // empty')
    else
        loc=$(printf '%s' "$json" | sed -nE 's/.*"loc"[[:space:]]*:[[:space:]]*"([0-9.-]+,[0-9.-]+)".*/\1/p')
    fi
    [ -n "$loc" ] && break
done
[ -n "${loc:-}" ] || exit 1
lat=${loc%,*}; lon=${loc#*,}
case "$lat" in -[0-9]*|[0-9]*) ;; *) exit 1 ;; esac
case "$lon" in -[0-9]*|[0-9]*) ;; *) exit 1 ;; esac
tmp=$(mktemp /tmp/geolocation.XXXXXX)
trap 'rm -f "$tmp"' EXIT
printf '%.4f\n%.4f\n0\n200\n' "$lat" "$lon" > "$tmp"
if ! cmp -s "$tmp" /etc/geolocation 2>/dev/null; then
    chmod 0644 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" /etc/geolocation
    echo "[$(date '+%F %T')] geolocation 更新为: $lat, $lon"
fi
UEOF
chmod 755 /usr/local/bin/update-geolocation.sh

cat > /etc/NetworkManager/dispatcher.d/50-update-geolocation <<'NEOF'
#!/bin/sh
[ "$2" = "up" ] || exit 0
/usr/local/bin/update-geolocation.sh >/dev/null 2>&1 || true
NEOF
chmod 755 /etc/NetworkManager/dispatcher.d/50-update-geolocation

cat > /etc/systemd/system/update-geolocation.service <<'SUNIT'
[Unit]
Description=Refresh geoclue static location from IP geolocation
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-geolocation.sh
SUNIT
cat > /etc/systemd/system/update-geolocation.timer <<'TUNIT'
[Unit]
Description=Refresh geoclue static location periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
TUNIT
systemctl daemon-reload
systemctl enable --now update-geolocation.timer >/dev/null
/usr/local/bin/update-geolocation.sh || true

echo "[5/6] 重启 geoclue 并验证"
systemctl restart geoclue.service 2>/dev/null || true
sleep 2
echo "  geoclue: $(systemctl is-active geoclue.service)  pid=$(pgrep -x geoclue || echo 无)"
echo "  /etc/geolocation: $(tr '\n' ' ' < /etc/geolocation 2>/dev/null)"
/usr/lib/geoclue-2.0/demos/agent >/dev/null 2>&1 &
AGPID=$!
sleep 1
timeout 20 /usr/lib/geoclue-2.0/demos/where-am-i 2>/dev/null | grep -E 'Latitude|Longitude|Description' || echo "  [!] 未取到位置"
kill $AGPID 2>/dev/null || true

echo "[6/6] 重启 knighttimed 使其使用新位置"
systemctl --user restart plasma-knighttimed 2>/dev/null || true
sleep 5
echo
echo "完成！在 系统设置→颜色与主题→Day-Night Cycle 确认位置为『自动检测』。"
echo "注意：切换地区时请关闭代理（或让 ipinfo.io/ipwho.is 走直连），否则坐标会偏移。"
