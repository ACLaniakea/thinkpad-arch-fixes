#!/bin/bash
# 用 ipinfo 查询经纬度写入 /etc/geolocation（geoclue 静态源实时读取）。
# 代理处理：剥离代理环境变量 + curl --noproxy，强制直连（可绕过 HTTP/SOCKS 代理；
# TUN/全局代理需在代理规则中放行 ipinfo.io/ipwho.is）。
set -u

direct_curl() {
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        curl --noproxy '*' --max-time 10 -fsS "$@"
}
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
printf '%.4f\n%.4f\n0\n200\n' "$lat" "$lon" > /tmp/geolocation.new
if ! cmp -s /tmp/geolocation.new /etc/geolocation 2>/dev/null; then
    cp /tmp/geolocation.new /etc/geolocation
    echo "[$(date '+%F %T')] geolocation 更新为: $lat, $lon"
fi
