# ThinkPad X13 Gen 4 · Arch Linux 修正脚本集

面向 **ThinkPad X13 Gen 4（AMD） + Arch Linux + KDE Plasma 6** 的六个独立修正脚本。
每个脚本相互独立、幂等（可重复运行），`sudo bash <script>.sh` 即可。

| 脚本 | 作用 |
|---|---|
| `01-autotimezone.sh` | 自动时区：KDE geotimezoned + ipinfo 兜底 + NTP |
| `02-f4-led-sync.sh` | F4 麦克风静音指示灯跟随软件静音状态 |
| `03-tlp-hibernate.sh` | TLP 省电策略 + 合盖挂起后自动休眠 |
| `04-autodaynight.sh` | KDE 自动黑白（Day-Night 定位）：ipinfo → geoclue 静态源 → 日落切换 |
| `05-fix-kioworker-calligra.sh` | 修复 kioworker 崩溃：禁用 Calligra 缩略图插件（可选彻底卸载） |
| `06-fix-captive-portal.sh` | 强制门户登录页修复：连通性检查 + open-captive-portal 助手 |
| `07-fix-hibernate-root.sh` | 每次睡眠前禁用 S4 虚假唤醒源，清理旧休眠覆盖 |

## 前提与依赖

- Arch Linux（systemd、NetworkManager、GRUB[^1]），KDE Plasma 6（Wayland）
- `01`：plasma-workspace（含 geotimezoned）、qt6-tools（qdbus6）、polkit、curl
- `02`：pipewire-pulse（wpctl/pactl）
- `03`：tlp、grub、mkinitcpio（systemd hook），并安装每次睡眠前的唤醒源 hook
- `04`：geoclue、curl、qt6-positioning

[^1]: `03` 依赖 GRUB。若使用 systemd-boot，脚本会提示你手动把 `resume=UUID=<swap-uuid>`
      加到 loader entry 的内核参数。

## 各脚本说明

### 01 自动时区
- 主通道：KDE `geotimezoned` 按 `geoip.kde.org` 的出口 IP 切时区（polkit 免密授权）。
- 兜底：`/usr/local/bin/update-system-timezone.sh` 用 ipinfo/ipwhois（`--noproxy`），
  NetworkManager 联网触发 + 每 30 分钟定时器。
- 中国全境统一北京时间：ipinfo 对新疆返回 `Asia/Urumqi`，脚本会映射回 `Asia/Shanghai`。
- 注意：代理需让 `geoip.kde.org`、`ipinfo.io`、`ipwho.is` 走直连。

### 02 F4 LED 同步
- 背景：F4 是硬件 micmute LED，只随 F4 键走；软件静音（PipeWire/KDE）不会驱动它。
- 方案：udev 放开 LED 写权限 + 用户级服务 `micmute-led.service` 同步
  （pactl 事件驱动 ~30ms 即时响应 + 1.5s 轮询兜底，PipeWire 重启可自愈）。

### 03 TLP + 休眠
- TLP：插电=性能档(PRF)，电池=省电档(SAV)，PCIe ASPM powersave，核显 DPM low。
- 休眠：自动探测 swap UUID → `resume=` 内核参数 → 重新生成 GRUB；
  合盖=挂起，1 小时后自动休眠（`HibernateDelaySec=3600`）。
- 修复：删除旧的 `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS` 覆盖；纯 AMD 机器不使用该
  NVIDIA 遗留 hack。每次进入睡眠前重新关闭已知 S4 唤醒源。
- 注意：跑完后**必须重启一次**，然后测试 `sudo systemctl hibernate`；
  改延迟见 `/etc/systemd/sleep.conf.d/10-thinkpad-hibernate.conf` 的
  `HibernateDelaySec`（秒）。

### 04 自动黑白（Day-Night Cycle）
- 无 GPS/蜂窝时，WiFi 众包库与 geoclue 自带 IP 库可能不准；本方案用 ipinfo
  （按出口 IP，实测较准）查坐标 → 写 `/etc/geolocation` → geoclue 静态源实时读取
  → KDE knighttimed 计算日出日落。
- 自动更新：NetworkManager 联网触发 + 每 30 分钟定时器（`--noproxy`）。
- 关键修复：geoclue `-t 0` 常驻（否则 D-Bus 冷激活会丢消息，QtPositioning 插件连不上）。
- 注意：切换地区时关代理或让 `ipinfo.io`/`ipwho.is` 走直连。

## 使用

> 05/06 为故障修复脚本：05 处理 Dolphin 缩略图 worker（kioworker）崩溃；06 处理强制门户网络登录页打不开/被重定向到连通性测试页的问题。


```bash
sudo bash 01-autotimezone.sh   # 自动时区
sudo bash 02-f4-led-sync.sh    # F4 LED
sudo bash 03-tlp-hibernate.sh  # TLP + 休眠（需重启）
sudo bash 04-autodaynight.sh   # 自动黑白
sudo bash 05-fix-kioworker-calligra.sh
sudo bash 06-fix-captive-portal.sh
sudo bash 07-fix-hibernate-root.sh  # 可选：单独重装休眠唤醒源 hook
```

## 许可

MIT License。
