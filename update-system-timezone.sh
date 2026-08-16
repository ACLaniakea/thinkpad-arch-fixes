#!/bin/bash
# 按出口 IP 获取时区并设置（--noproxy：代理会返回代理所在地时区）
# 中国全境统一使用北京时间（官方时区）：ipinfo 对新疆返回 Asia/Urumqi，映射回 Asia/Shanghai
set -u
zone=""
for url in https://ipinfo.io/json https://ipwho.is/; do
    json=$(curl --noproxy '*' -fsS --max-time 10 "$url" 2>/dev/null) || continue
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
