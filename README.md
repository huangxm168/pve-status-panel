# pve-status-panel

在 Proxmox VE 节点「概览（Summary）」卡片中显示 **CPU 主频、温度 / 风扇、每块 NVMe / 磁盘的 SMART 与 I/O** 等硬件信息。

这是社区脚本 [KoolCore/Proxmox_VE_Status](https://github.com/KoolCore/Proxmox_VE_Status) 的**加固版**：保留其经过验证的信息渲染逻辑，替换掉脆弱 / 不安全的落地方式。

## 与上游相比改了什么

| 方面           | 上游脚本                                                                           | 本项目                                                                                                                  |
| -------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **setuid**     | 给 `smartctl` / `iostat` 加 setuid root                                            | **不加**（节点状态 API 本以 root 运行，setuid 是多余的本地提权面）                                                      |
| **采集架构**   | 硬件命令**同步内联**在 status API 里跑（阻塞接口、撞 `perl -T` 污点、逼出 setuid） | **采集与注入解耦 + 按需**：常驻守护经 inotify 被查看时才采样写 `/run`，后端只读回填——不阻塞接口、无污点、空闲零唤醒磁盘 |
| **升级存活**   | 直接改 `pve-manager` 包内文件，升级即被覆盖、面板消失                              | **APT `DPkg::Post-Invoke` 自愈 hook**：每次 `apt` 后幂等重打，升级不丢                                                  |
| **注入方式**   | 晦涩的 `sed`（`//!d` 之类）                                                        | **`BEGIN/END` 标记块注入** + 后端 `perl -c` 语法校验，失败**自动回滚**，绝不弄坏节点 API                                |
| **驱动安装**   | 脚本内 `git clone` 编译 it87、改软件源、跑 `apt full-upgrade`                      | **不做**。面板只读现有传感器；驱动 / 源是宿主机自身配置，不越界                                                         |
| **传感器来源** | 仅解析 `lm-sensors`                                                                | **板级双线路**：有可用 IPMI 走 `ipmitool`（服务器板），否则回落 `lm-sensors`（消费级板）                                |
| **还原**       | 6 行脚本只反注入 JS/Perl                                                           | 完整 `restore.sh`：摘 hook + 经 `.orig` 快照精确还原官方原版                                                            |

## 工作原理

面板信息需要注入 PVE 两个自带文件才能出现在「概览」卡片：

- 后端 `PVE/API2/Nodes.pm`（Perl）：给节点 `status` API 增加 `cpu_frequency` / `cpu_temperatures` / `nvmeX_status` 等字段；
- 前端 `pvemanagerlib.js`（JS）：把这些字段渲染成卡片行。

这两个文件归 `pve-manager` 包所有，**升级即被官方原版覆盖** —— 这正是「升级后面板消失」的根因。本项目用 APT 自愈 hook 在每次 `apt` 后自动重打来根治。

硬件采集与后端注入是**解耦**且**按需**的：注入进 `Nodes.pm` 的 Perl 块**只读** `/run/pve-status-panel/` 下的文件回填字段，真正跑 `ipmitool` / `smartctl` / `iostat` 的是一个独立的**常驻采集守护**（普通 root 上下文的 systemd 服务）。这样设计有两层原因：

- **为什么解耦**：PVE 的 Web API 跑在 `perl -T` 污点模式、其上下文又看不到 `/dev/ipmi0`、`/dev/nvme*`，无法在 status 处理函数里直接跑硬件命令；改由守护在普通上下文采样、后端只「读文件」回填，既避开污点与设备限制，也更快、且无需 setuid。
- **为什么按需**：前端每次轮询节点状态时，后端顺手往 `/run/pve-status-panel/.poll` 写个时间戳，守护经 `inotify` 收到变化才采一次（并受「最小采样间隔」节流）。于是**没人查看概览时守护一直睡着、零采样、零磁盘唤醒**；一旦有人打开概览就自动开始采，首屏即有数据（守护启动时已预热一次）。守护常驻只在开机记一次日志，不产生逐次噪声。

## 安装

```bash
git clone https://github.com/huangxm168/pve-status-panel.git
cd pve-status-panel
sudo ./install.sh          # 或 sudo ./install.sh 3   指定最小采样间隔（秒，默认 5）
```

安装：清除 `smartctl`/`iostat` 的 setuid 基线、部署 `pve-status-panel` 到 `/usr/local/bin`、注入 + 部署常驻采集守护、安装 APT 自愈 hook、首次应用。按需采集依赖 `inotify-tools`——检测到 `/dev/ipmi0` 但缺 `ipmitool`、或缺 `inotifywait` 时会自动 `apt` 安装（`ipmitool` 装不上回落 lm-sensors；`inotifywait` 装不上守护退化为 2 秒 mtime 轮询）。完成后在浏览器 **Ctrl+Shift+R** 强刷即可看到。

**采集时机与频率**：采集**按需**进行——没人查看概览时不采样、不唤醒磁盘；有人查看时，前端每轮询一次就触发守护采一次，并受「最小采样间隔」节流（默认 5 秒）。安装时用后缀参数指定（`./install.sh 3`），或随时 `pve-status-panel set-interval <秒>` 修改（≥2 秒；改后下次采集即生效、重启仍生效）。注：前端 PVE 自身每 5 秒轮询一次节点状态，故把间隔设得比 5 秒更小并不会让界面刷新更快。

## 卸载 / 还原

```bash
sudo ./restore.sh          # 还原官方原版（保留 applier 与快照）
sudo ./restore.sh --full   # 彻底卸载
```

## 常用命令

```bash
pve-status-panel status         # 查看模式 / 注入状态 / hook / 采集守护 / 风扇是否就位
pve-status-panel apply          # 手动重打（幂等；hook 亦会自动调用）
pve-status-panel restore        # 还原官方原版
pve-status-panel setup-sensors  # 消费级板：探测并加载 Super I/O 风扇驱动（不编译，持久化）
pve-status-panel set-interval 3 # 修改最小采样间隔（秒，≥2）
PSP_MODE=sensors pve-status-panel apply   # 强制指定数据源（ipmi|sensors）
```

## 数据源模式

- **ipmi**：存在 `/dev/ipmi0` 且 `ipmitool sdr` 可读时自动选用。温度 / 风扇来自 BMC，覆盖 CPU / 主板 / 网卡 / 内存 温度与全部风扇，稳定且不依赖内核版本。适合带 BMC 的服务器主板（如 ASRock Rack ROMED8-2T）。
- **sensors**：无 IPMI 时回落，解析 `lm-sensors`。温度按芯片分组、友好标签（`k10temp`/`coretemp`→CPU、`amdgpu`→GPU，其余保留芯片名）、跳过 NVMe（已有独立卡片）；风扇过滤 0 RPM（未接的插座不显）。适合消费级主板。

  消费级板的风扇/主板温挂在 Super I/O 芯片（Nuvoton `nct67xx` 用 `nct6775` 驱动、ITE 用 `it87` 等），全新系统默认不加载。跑一次 `pve-status-panel setup-sensors` 即可：它按序试探一组内核自带驱动（`nct6775` / `nct6683` / `it87` / `w83627ehf` / `f71882fg`，**不编译、不 dkms**）、命中即持久化到 `/etc/modules-load.d/`，采集守护下次采集（有人查看时触发）自动读到风扇——之后永久自动。搞不定的少数情况（ACPI 占用需 `acpi_enforce_resources=lax` / 芯片过新）只提示不硬来。

## 兼容性与说明

- 面向 **PVE 8 / 9**（deb822 与传统源皆可；注入锚点基于官方 `Nodes.pm` / `pvemanagerlib.js` 结构）。
- 后端注入带 `perl -c` 校验 + 回滚：即便未来某版本改了锚点导致注入不匹配，也只是面板不显示，**不会弄坏节点 API**。
- 前端注入若锚点失配则该次不生效；不影响 SSH / API，`restore.sh` 可随时还原。
- 已在两类真机完整验证：**IPMI 模式 + AMD EPYC（ROMED8-2T / PVE 9）** 与 **sensors 模式 + AMD Ryzen 9700X（ASUS X870E / PVE 8）**——apply / restore / 幂等 / 升级自愈 / `perl -c` / `node --check` / setup-sensors 均通过；PVE 8 与 9 注入锚点一致。
- 采集**按需**触发：空闲（无人查看概览）时不运行任何硬件命令、不唤醒磁盘；有人查看期间，守护按「最小采样间隔」运行 `ipmitool` / `smartctl` / `iostat` 采样并唤醒磁盘，属该类面板固有代价。

## 致谢

信息渲染逻辑源自 [KoolCore/Proxmox_VE_Status](https://github.com/KoolCore/Proxmox_VE_Status)，在此致谢。本项目在其基础上做安全与可维护性加固。

## License

GPL-3.0（沿用上游 it87 等 GPL 组件的许可惯例；渲染逻辑衍生自上游）。
