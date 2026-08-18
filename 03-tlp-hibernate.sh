#!/bin/bash
# =============================================================================
# 03-tlp-hibernate.sh — TLP + suspend-then-hibernate · ThinkPad X13 Gen 4
#
# 目标：
#   1. 插电使用 PRF，电池使用 SAV；只在电池侧启用更激进的 ASPM/GPU DPM。
#   2. 为实际使用的 swap 分区配置 resume=，并重建 initramfs/GRUB。
#   3. 合盖先挂起，HibernateDelaySec=3600 后再进入休眠。
#   4. AMD-only 机器覆盖 NVIDIA 包带来的 no-freeze 设置，保证挂起转休眠可靠。
#   5. 每次进入睡眠前重新关闭已知的 S4 虚假唤醒源，避免驱动在开机后重新打开。
#
# 用法：sudo bash 03-tlp-hibernate.sh
# =============================================================================
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo bash $0" >&2; exit 1; }

die() { echo "[错误] $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

need systemctl
need lsblk
need lspci
need sed
need awk

echo "[1/5] 配置并启用 TLP"
TLP_CONF=/etc/tlp.conf
touch "$TLP_CONF"
tlp_tmp=$(mktemp)
trap 'rm -f "$tlp_tmp"' EXIT

# 新块带 BEGIN/END，重复执行不会误删后续用户配置；兼容清理旧版本末尾块。
awk '
    /^# === thinkpad-tlp-strategy BEGIN ===$/ { skip=1; next }
    /^# === thinkpad-tlp-strategy END ===$/   { skip=0; next }
    /^# === thinkpad-tlp-strategy ===$/       { skip=1; next }
    /^# === auto-tlp-strategy 2026-08-14 ===$/ { skip=1; next }
    !skip { print }
' "$TLP_CONF" > "$tlp_tmp"
cat >> "$tlp_tmp" <<'EOF'

# === thinkpad-tlp-strategy BEGIN ===
TLP_PROFILE_AC="PRF"
TLP_PROFILE_BAT="SAV"
PCIE_ASPM_ON_BAT="powersave"
PCIE_ASPM_ON_SAV="powersave"
RADEON_DPM_PERF_LEVEL_ON_BAT="low"
RADEON_DPM_PERF_LEVEL_ON_SAV="low"
# === thinkpad-tlp-strategy END ===
EOF
install -m 0644 "$tlp_tmp" "$TLP_CONF"
rm -f "$tlp_tmp"
trap - EXIT

systemctl enable --now tlp.service >/dev/null
systemctl reload tlp.service >/dev/null
if command -v tlp-stat >/dev/null 2>&1; then
    tlp-stat -s 2>/dev/null | sed -n '/TLP Status/,+6p' || true
fi

echo "[2/5] 配置休眠恢复设备"
SWAP_DEV=""
SWAP_UUID=""
while read -r candidate _; do
    [[ "$candidate" == /dev/* ]] || continue
    candidate_uuid=$(lsblk -no UUID "$candidate" 2>/dev/null | head -n 1)
    if [ -n "$candidate_uuid" ]; then
        SWAP_DEV="$candidate"
        SWAP_UUID="$candidate_uuid"
        break
    fi
done < <(awk 'NR > 1 { print $1 }' /proc/swaps)

[ -n "$SWAP_DEV" ] || die "未找到带 UUID 的 swap 分区；当前脚本不自动处理 swap 文件/zram。"
echo "  swap: $SWAP_DEV (UUID=$SWAP_UUID)"

if [ -f /etc/default/grub ]; then
    need grub-mkconfig
    grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || \
        die "/etc/default/grub 缺少 GRUB_CMDLINE_LINUX_DEFAULT"
    if ! grep -q "resume=UUID=$SWAP_UUID" /etc/default/grub; then
        sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"|\1 resume=UUID=$SWAP_UUID\"|" /etc/default/grub
        echo "  已写入 resume=UUID=$SWAP_UUID"
    else
        echo "  resume= 已存在"
    fi
    if [ -f /etc/mkinitcpio.conf ] && ! grep -qE '(^|[[:space:]()])systemd([[:space:]()"]|$)' /etc/mkinitcpio.conf; then
        echo "  [!] mkinitcpio 未检测到 systemd hook；请确认 initramfs 的 resume 配置。" >&2
    fi
    if command -v mkinitcpio >/dev/null 2>&1; then
        mkinitcpio -P >/dev/null
        echo "  initramfs 已重建"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
    echo "  GRUB 已重新生成"
else
    die "未检测到 GRUB；请手动把 resume=UUID=$SWAP_UUID 写入 systemd-boot entry 的 options。"
fi

echo "[3/5] 配置合盖挂起→1 小时后休眠"
install -d -m 0755 /etc/systemd/sleep.conf.d /etc/systemd/logind.conf.d
cat > /etc/systemd/sleep.conf.d/10-thinkpad-hibernate.conf <<'EOF'
[Sleep]
HibernateDelaySec=3600
EOF
cat > /etc/systemd/logind.conf.d/60-thinkpad-hibernate.conf <<'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
EOF
# 清理旧脚本直接写入主配置的同名行，避免重复配置。
sed -i '/^HandleLidSwitch=suspend-then-hibernate$/d; /^HandleLidSwitchExternalPower=suspend-then-hibernate$/d' /etc/systemd/logind.conf 2>/dev/null || true

echo "[4/5] 安装每次睡眠前的 S4 唤醒源修复"
WAKEUP_SCRIPT=/usr/local/sbin/thinkpad-disable-wakeup.sh
SLEEP_HOOK=/usr/lib/systemd/system-sleep/00-thinkpad-wakeup
cat > "$WAKEUP_SCRIPT" <<'EOF'
#!/bin/bash
# Disable spurious PCI wakeup sources before every suspend/hibernate.
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
# systemd-sleep passes: pre|post and suspend|hibernate|hybrid-sleep|suspend-then-hibernate.
[ "${1:-}" = pre ] || exit 0
exec /usr/local/sbin/thinkpad-disable-wakeup.sh
EOF
chmod 0755 "$SLEEP_HOOK"

# 保留开机时的初始设置，但不再依赖它：驱动可能在开机后重新打开 wakeup，
# 所以真正关键的是上面的 system-sleep hook。
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

echo "[5/5] 修正用户会话冻结策略并重新加载配置"
for unit in systemd-hibernate systemd-suspend systemd-suspend-then-hibernate systemd-hybrid-sleep; do
    dropin_dir="/etc/systemd/system/${unit}.service.d"
    old="${dropin_dir}/zz-fix-freeze-session.conf"
    if [ -f "$old" ]; then
        rm -f "$old"
        echo "  已删除 $old"
    fi
    if ! lspci -Dn 2>/dev/null | awk '$2 ~ /^030[02]:/ && $3 ~ /^10de:/ { found=1 } END { exit !found }'; then
        install -d -m 0755 "$dropin_dir"
        cat > "${dropin_dir}/20-thinkpad-freeze-session.conf" <<'EOF'
[Service]
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true"
EOF
    else
        rm -f "${dropin_dir}/20-thinkpad-freeze-session.conf"
        rmdir "$dropin_dir" 2>/dev/null || true
        echo "  检测到 NVIDIA 显卡，保留发行版 no-freeze 策略"
    fi
done
systemctl daemon-reload
systemctl reload systemd-logind.service >/dev/null 2>&1 || \
    echo "  [!] logind reload 未成功；重启后必然重新读取配置。" >&2

echo
echo "===== 当前配置 ====="
grep -E 'GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub
cat /etc/systemd/sleep.conf.d/10-thinkpad-hibernate.conf
cat /etc/systemd/logind.conf.d/60-thinkpad-hibernate.conf
echo "唤醒源："
grep -E 'GPP6|GP11|GP12|XHC1|NHI1|LID|SLPB' /proc/acpi/wakeup 2>/dev/null || true
echo
echo "完成。已安装每次睡眠前的唤醒源 hook；请先拔掉/卸载 USB 外置盘，再手动测试："
echo "  sudo systemctl hibernate"
