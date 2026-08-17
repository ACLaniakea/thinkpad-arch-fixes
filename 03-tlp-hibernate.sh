#!/bin/bash
# =============================================================================
# 03-tlp-hibernate.sh — TLP 省电 + suspend-then-hibernate 休眠 · ThinkPad X13 Gen 4 · Arch Linux
#
# 内容：
#   1. TLP 策略：插电=性能档(PRF)，电池=省电档(SAV)，PCIe ASPM powersave，核显 DPM low
#   2. 休眠恢复：自动探测 swap 分区 UUID 写入 resume= 内核参数；
#      加 amdgpu.runpm=0 缓解 RDNA3 休眠挂起(GPU复位失败)，重新生成 GRUB
#   3. 合盖=挂起、1 小时后自动休眠（suspend-then-hibernate，HibernateDelaySec=3600）
#   4. 修复：覆盖 nvidia-utils 的 no-freeze-session 设置（纯 AMD 机器不需要，
#      不冻结会话会导致休眠镜像写入卡死/无法恢复）
#
# 用法：sudo bash 03-tlp-hibernate.sh
# 依赖：tlp、grub、mkinitcpio(systemd hook)、systemd
# 注意：跑完后必须重启一次让 resume= 生效，然后测试：sudo systemctl hibernate
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo bash $0" >&2; exit 1; }

echo "[1/4] TLP 省电策略"
TLP_CONF=/etc/tlp.conf
# 移除旧块（兼容之前两个版本的标记）
for marker in '# === thinkpad-tlp-strategy ===' '# === auto-tlp-strategy 2026-08-14 ==='; do
    if grep -qF "$marker" "$TLP_CONF" 2>/dev/null; then
        sed -i "/^$(printf '%s' "$marker" | sed 's/[.[\*^$()+?{}|\\]/\\&/g')$/,\$d" "$TLP_CONF"
    fi
done
cat >> "$TLP_CONF" <<'EOF'

# === thinkpad-tlp-strategy ===
TLP_PROFILE_AC="PRF"
TLP_PROFILE_BAT="SAV"
PCIE_ASPM_ON_BAT="powersave"
PCIE_ASPM_ON_SAV="powersave"
RADEON_DPM_PERF_LEVEL_ON_BAT="low"
RADEON_DPM_PERF_LEVEL_ON_SAV="low"
EOF
systemctl restart tlp >/dev/null 2>&1 || true
echo "  当前 TLP profile: $(tlp-stat -s 2>/dev/null | sed -n 's/.*TLP profile.*= //p' || echo 未知)"

echo "[2/4] 休眠恢复内核参数 resume="
if [ ! -f /etc/default/grub ]; then
    echo "  [!] 未检测到 GRUB（可能是 systemd-boot）。"
    echo "      请手动把 resume=UUID=<swap-uuid> 加到 /boot/loader/entries/*.conf 的 options 行。"
fi
SWAP_DEV=$(awk 'NR==2{print $1}' /proc/swaps)
if [ -z "${SWAP_DEV:-}" ]; then
    echo "  [错误] 未检测到 swap 分区，休眠不可用（请先创建 swap）" >&2
    exit 1
fi
SWAP_UUID=$(lsblk -no UUID "$SWAP_DEV" 2>/dev/null | head -1)
[ -n "${SWAP_UUID:-}" ] || { echo "  [错误] 无法读取 $SWAP_DEV 的 UUID" >&2; exit 1; }
echo "  swap: $SWAP_DEV (UUID=$SWAP_UUID)"
if grep -q "resume=UUID=$SWAP_UUID" /etc/default/grub; then
    echo "  resume= 已存在，跳过"
else
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 resume=UUID=$SWAP_UUID\"/" /etc/default/grub
    echo "  已写入 resume=UUID=$SWAP_UUID"
fi
# amdgpu(RDNA3) 休眠时偶发 GPU job 超时 + MODE2 复位失败导致挂起/睡死
# runpm=0 是常用缓解参数（关闭 GPU 运行时电源管理，避免挂起阶段超时）
if grep -q 'amdgpu.runpm=0' /etc/default/grub; then
    echo "  amdgpu.runpm=0 已存在，跳过"
else
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amdgpu.runpm=0"/' /etc/default/grub
    echo "  已写入 amdgpu.runpm=0"
fi
grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
echo "  GRUB 已重新生成"

echo "[3/4] 合盖 = 挂起后 1 小时自动休眠"
mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/10-thinkpad-hibernate.conf <<'EOF'
[Sleep]
HibernateDelaySec=3600
EOF
sed -i '/^HibernateDelaySec=/d' /etc/systemd/sleep.conf 2>/dev/null || true
sed -i '/^HandleLidSwitch=/d; /^HandleLidSwitchExternalPower=/d' /etc/systemd/logind.conf
if grep -q '^\[Login\]' /etc/systemd/logind.conf; then
    sed -i '/^\[Login\]/a HandleLidSwitch=suspend-then-hibernate\nHandleLidSwitchExternalPower=suspend-then-hibernate' /etc/systemd/logind.conf
else
    printf '\n[Login]\nHandleLidSwitch=suspend-then-hibernate\nHandleLidSwitchExternalPower=suspend-then-hibernate\n' >> /etc/systemd/logind.conf
fi

echo "[4/4] 修复休眠镜像写入：强制冻结用户会话（覆盖 nvidia-utils 干扰）"
for unit in systemd-hibernate systemd-suspend-then-hibernate systemd-hybrid-sleep; do
    d="/etc/systemd/system/${unit}.service.d"
    mkdir -p "$d"
    printf '[Service]\nEnvironment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true"\n' > "$d/zz-fix-freeze-session.conf"
done
systemctl daemon-reload

echo
echo "===== 验证 ====="
grep -E 'GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub
grep -E 'HibernateDelaySec' /etc/systemd/sleep.conf.d/10-thinkpad-hibernate.conf
grep -E 'HandleLidSwitch' /etc/systemd/logind.conf
systemctl show systemd-hibernate.service -p Environment | sed 's/^/  /'
echo
echo "完成！下一步："
echo "  1) 重启一次（让 resume= 生效）"
echo "  2) 保存工作后测试: sudo systemctl hibernate"
echo "  3) 之后合盖 = 先挂起，1 小时后自动休眠（几乎零耗电）"
