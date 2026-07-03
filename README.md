# pve-status-panel

在 Proxmox VE 节点「概览（Summary）」卡片中显示 **CPU 主频、温度 / 风扇、每块 NVMe / 磁盘的 SMART 与 I/O** 等硬件信息。

这是社区脚本 [KoolCore/Proxmox_VE_Status](https://github.com/KoolCore/Proxmox_VE_Status) 的**「取其精华去其糟粕」加固版**：保留其经过验证的信息渲染逻辑，替换掉脆弱 / 不安全的落地方式。

## 与上游相比改了什么

| 方面 | 上游脚本 | 本项目 |
| --- | --- | --- |
| **setuid** | 给 `smartctl` / `iostat` 加 setuid root | **不加**（节点状态 API 本以 root 运行，setuid 是多余的本地提权面） |
| **升级存活** | 直接改 `pve-manager` 包内文件，升级即被覆盖、面板消失 | **APT `DPkg::Post-Invoke` 自愈 hook**：每次 `apt` 后幂等重打，升级不丢 |
| **注入方式** | 晦涩的 `sed`（`//!d` 之类） | **`BEGIN/END` 标记块注入** + 后端 `perl -c` 语法校验，失败**自动回滚**，绝不弄坏节点 API |
| **驱动安装** | 脚本内 `git clone` 编译 it87、改软件源、跑 `apt full-upgrade` | **不做**。面板只读现有传感器；驱动 / 源是宿主机自身配置，不越界 |
| **传感器来源** | 仅解析 `lm-sensors` | **板级双线路**：有可用 IPMI 走 `ipmitool`（服务器板），否则回落 `lm-sensors`（消费级板） |
| **还原** | 6 行脚本只反注入 JS/Perl | 完整 `restore.sh`：摘 hook + 经 `.orig` 快照精确还原官方原版 |

## 工作原理

面板信息需要注入 PVE 两个自带文件才能出现在「概览」卡片：

- 后端 `PVE/API2/Nodes.pm`（Perl）：给节点 `status` API 增加 `cpu_frequency` / `cpu_temperatures` / `nvmeX_status` 等字段；
- 前端 `pvemanagerlib.js`（JS）：把这些字段渲染成卡片行。

这两个文件归 `pve-manager` 包所有，**升级即被官方原版覆盖** —— 这正是「升级后面板消失」的根因。本项目用 APT 自愈 hook 在每次 `apt` 后自动重打来根治。

## 安装

```bash
git clone https://github.com/<your-account>/pve-status-panel.git
cd pve-status-panel
sudo ./install.sh
```

安装做四件事：清除 `smartctl`/`iostat` 的 setuid 基线、部署 `pve-status-panel` 到 `/usr/local/bin`、安装 APT 自愈 hook、首次应用。完成后在浏览器 **Ctrl+Shift+R** 强刷即可看到。

## 卸载 / 还原

```bash
sudo ./restore.sh          # 还原官方原版（保留 applier 与快照）
sudo ./restore.sh --full   # 彻底卸载
```

## 常用命令

```bash
pve-status-panel status     # 查看模式 / 注入状态 / hook 是否就位
pve-status-panel apply      # 手动重打（幂等；hook 亦会自动调用）
pve-status-panel restore    # 还原官方原版
PSP_MODE=sensors pve-status-panel apply   # 强制指定数据源（ipmi|sensors）
```

## 数据源模式

- **ipmi**：存在 `/dev/ipmi0` 且 `ipmitool sdr` 可读时自动选用。温度 / 风扇来自 BMC，覆盖 CPU / 主板 / 网卡 / 内存 温度与全部风扇，稳定且不依赖内核版本。适合带 BMC 的服务器主板（如 ASRock Rack ROMED8-2T）。
- **sensors**：无 IPMI 时回落，解析 `lm-sensors`（复用上游 Intel `coretemp` / AMD `k10temp` / it87 风扇 / amdgpu 渲染）。适合消费级主板；需宿主机自行用 `sensors-detect` 配好传感器。

## 兼容性与说明

- 面向 **PVE 8 / 9**（deb822 与传统源皆可；注入锚点基于官方 `Nodes.pm` / `pvemanagerlib.js` 结构）。
- 后端注入带 `perl -c` 校验 + 回滚：即便未来某版本改了锚点导致注入不匹配，也只是面板不显示，**不会弄坏节点 API**。
- 前端注入若锚点失配则该次不生效；不影响 SSH / API，`restore.sh` 可随时还原。
- 本仓当前在 **IPMI 模式 + AMD EPYC（ROMED8-2T）** 上完整验证（apply / restore / 幂等 / 升级自愈 / `perl -c` / `node --check` 全过）。`sensors` 模式渲染逻辑源自上游、结构保留，建议在消费级主板上再行验证。
- 每次「概览」刷新会运行 `ipmitool` / `smartctl` / `iostat` 采样，有轻微开销并会唤醒磁盘，属该类面板固有代价。

## 致谢

信息渲染逻辑源自 [KoolCore/Proxmox_VE_Status](https://github.com/KoolCore/Proxmox_VE_Status)，在此致谢。本项目在其基础上做安全与可维护性加固。

## License

GPL-3.0（沿用上游 it87 等 GPL 组件的许可惯例；渲染逻辑衍生自上游）。
