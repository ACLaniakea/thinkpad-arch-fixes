#!/bin/bash
# =============================================================================
# 02-f4-led-sync.sh — F4 麦克风静音指示灯同步 · ThinkPad X13 Gen 4 · Arch Linux
#
# 背景：F4 的 platform::micmute 是硬件 LED，只随 F4 键切换；用软件静音
#       （PipeWire/KDE 快捷设置/命令）不会驱动它，导致灯与实际静音状态脱节。
# 方案：udev 放开 LED 写权限 + 用户级 systemd 服务同步。
#       同步采用"事件驱动 + 轮询兜底"双通道：
#         - pactl subscribe 事件即时响应（~30ms）
#         - 1.5s 轮询兜底，覆盖 PipeWire 重启 / 事件丢失等场景
#
# 用法：sudo bash 02-f4-led-sync.sh
# 依赖：pipewire-pulse(pactl/wpctl)、systemd
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

echo "[1/3] udev 规则：放开 micmute LED 读写权限"
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-micmute-led.rules <<'RULE'
SUBSYSTEM=="leds", KERNEL=="platform::micmute", RUN+="/usr/bin/chmod 0666 /sys/class/leds/platform::micmute/brightness /sys/class/leds/platform::micmute/trigger"
RULE
udevadm control --reload-rules
udevadm trigger --subsystem-match=leds >/dev/null 2>&1 || true
chmod 0666 /sys/class/leds/platform::micmute/brightness /sys/class/leds/platform::micmute/trigger 2>/dev/null || true

echo "[2/3] 安装用户级同步脚本"
mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/systemd/user"
cat > "$TARGET_HOME/.local/bin/micmute-led-sync.sh" <<'LED'
#!/bin/bash
# 事件驱动(pactl subscribe 即时) + 轮询兜底(1.5s) 双通道：
# 平时 ~30ms 响应；pactl 事件丢失或 PipeWire 重启时由轮询兜底自愈。
set -u
led=/sys/class/leds/platform::micmute/brightness
led_dir=${led%/*}
last=''

sync_led() {
    [ -w "$led" ] || return 0
    printf 'none' > "$led_dir/trigger" 2>/dev/null || true
    state=0
    if wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q 'MUTED'; then
        state=1
    fi
    if [ "$state" != "$last" ]; then
        printf '%s' "$state" > "$led" 2>/dev/null || true
        last=$state
    fi
}

sync_led

# 事件通道（后台）
( pactl subscribe 2>/dev/null | while IFS= read -r ev; do
    case "$ev" in
        *"'change' on source "*|*"'new' on source "*|*"'remove' on source "*)
            sync_led ;;
    esac
done ) &

# 轮询兜底（前台）
while :; do
    sleep 1.5
    sync_led
done
LED
chmod 755 "$TARGET_HOME/.local/bin/micmute-led-sync.sh"

cat > "$TARGET_HOME/.config/systemd/user/micmute-led.service" <<UNIT
[Unit]
Description=Sync ThinkPad micmute LED with PipeWire microphone mute state
After=pipewire.service wireplumber.service

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/$TARGET_UID
ExecStart=%h/.local/bin/micmute-led-sync.sh
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNIT
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/systemd"

echo "[3/3] 启用并启动用户服务"
as_user systemctl --user daemon-reload >/dev/null 2>&1 || true
as_user systemctl --user enable --now micmute-led.service >/dev/null 2>&1 || echo "  [!] 无桌面会话，登录后自动生效"
sleep 1
echo "  服务: $(as_user systemctl --user is-active micmute-led.service 2>/dev/null || echo 未知)"
echo "  LED: $(cat /sys/class/leds/platform::micmute/brightness 2>/dev/null || echo 未知)"
echo
echo "完成！以后 F4 或软件切换静音，LED 会即时（~30ms）同步。"
