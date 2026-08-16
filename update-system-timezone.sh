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
