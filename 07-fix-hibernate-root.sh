#!/bin/bash
# =============================================================================
# 07-fix-hibernate-root.sh — ThinkPad X13 Gen 4 · S4 唤醒源修复
#
# 这个脚本现在与 03-tlp-hibernate.sh 使用同一套策略：
#   - AMD-only 机器覆盖 NVIDIA 包带来的 no-freeze 设置；
#   - 开机先设置一次唤醒源；
#   - 通过 systemd-sleep hook 在每次睡眠前再次设置，避免驱动重新打开 NHI1 等源。
#
# 用法：sudo bash 07-fix-hibernate-root.sh
# =============================================================================
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo bash $0" >&2; exit 1; }

for cmd in systemctl lspci awk install; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[错误] 缺少命令：$cmd" >&2; exit 1; }
done

WAKEUP_SCRIPT=/usr/local/sbin/thinkpad-disable-wakeup.sh
SLEEP_HOOK=/usr/lib/systemd/system-sleep/00-thinkpad-wakeup

echo "[1/4] 安装唤醒源处理脚本和每次睡眠前 hook"
cat > "$WAKEUP_SCRIPT" <<'EOF'
#!/bin/bash
set -u
PCI_DEVICES="0000:00:02.2 0000:00:03.1 0000:00:04.1 0000:c3:00.4 0000:c3:00.5 0000:c5:00.6"
for device in $PCI_DEVICES; do
    path="/sys/bus/pci/devices/$device/power/wakeup"
    [ -e "$path" ] || continue
    if [ -w "$path" ]; then
        if printf '%s\n' disabled > "$path"; then
            echo "wakeup disabled: $device"
        else
            echo "wakeup disable failed: $device" >&2
        fi
    fi
done
exit 0
EOF
chmod 0755 "$WAKEUP_SCRIPT"

cat > "$SLEEP_HOOK" <<'EOF'
#!/bin/sh
[ "$1" = pre ] || exit 0
exec /usr/local/sbin/thinkpad-disable-wakeup.sh
EOF
chmod 0755 "$SLEEP_HOOK"

echo "[2/4] 安装开机初始化服务"
cat > /etc/systemd/system/thinkpad-disable-wakeup.service <<'EOF'
[Unit]
Description=Disable spurious PCI wakeup sources (ThinkPad hibernate fix)
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thinkpad-disable-wakeup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl disable --now thinkpad-disable-wakeup.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now thinkpad-disable-wakeup.service >/dev/null
"$WAKEUP_SCRIPT"

echo "[3/4] 修正冻结用户会话策略"
for unit in systemd-hibernate systemd-suspend systemd-suspend-then-hibernate systemd-hybrid-sleep; do
    d="/etc/systemd/system/$unit.service.d"
    f="$d/zz-fix-freeze-session.conf"
    if [ -f "$f" ]; then
        rm -f "$f"
        echo "  已删除 $f"
    fi
    if ! lspci -Dn 2>/dev/null | awk '$2 ~ /^030[02]:/ && $3 ~ /^10de:/ { found=1 } END { exit !found }'; then
        install -d -m 0755 "$d"
        cat > "$d/20-thinkpad-freeze-session.conf" <<'EOF'
[Service]
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true"
EOF
    else
        rm -f "$d/20-thinkpad-freeze-session.conf"
        rmdir "$d" 2>/dev/null || true
        echo "  检测到 NVIDIA 显卡，保留发行版 no-freeze 策略"
    fi
done

echo "[4/4] 重新加载并验证"
systemctl daemon-reload
systemctl reload systemd-logind.service >/dev/null 2>&1 || \
    echo "  [!] logind reload 未成功；重启后会重新读取配置。" >&2
echo "--- systemd hook ---"
ls -l "$SLEEP_HOOK"
echo "--- /proc/acpi/wakeup ---"
grep -E 'GPP6|GP11|GP12|XHC1|NHI1|LID|SLPB' /proc/acpi/wakeup 2>/dev/null || true
echo
echo "完成。请拔掉/卸载 USB 外置盘后测试：sudo systemctl hibernate"
