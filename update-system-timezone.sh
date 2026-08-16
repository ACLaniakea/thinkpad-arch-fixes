#!/bin/bash
# 按出口 IP 获取时区并设置。
# 代理处理：剥离代理环境变量 + curl --noproxy，强制直连（可绕过 HTTP/SOCKS 代理；
# 若代理为 TUN/全局模式，脚本无法从用户态绕过，请在代理规则中放行 ipinfo.io/ipwho.is）。
# 中国全境统一北京时间：ipinfo 对新疆返回 Asia/Urumqi，映射回 Asia/Shanghai
set -u

direct_curl() {
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        curl --noproxy '*' --max-time 10 -fsS "$@"
}

# 网络层隧道检测：若公网出口走 TUN/TAP/WireGuard，出口 IP 已被代理改写，
# --noproxy 无法绕过，跳过自动更新避免污染。HTTP/SOCKS 代理无隧道，direct_curl 已绕过。
# 若确需在代理运行时更新，可创建 /etc/thinkpad-fixes.allow-proxy-location 放行。
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
[ "$current" = "$zone" ] || timedatectl set-timezone "$zone" >/dev/null 2>&1 || true
