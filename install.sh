#!/usr/bin/env bash
# 安装 pve-status-panel：在 PVE 节点「概览」卡片显示 CPU/温度·风扇/NVMe·磁盘 信息
# 加固安装：清 setuid 基线 + 部署 applier + 装 APT 自愈 hook + 首次应用
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN=/usr/local/bin/pve-status-panel
HOOK=/etc/apt/apt.conf.d/99-pve-status-panel

[ "$(id -u)" = 0 ] || { echo "请以 root 运行"; exit 1; }
command -v pvesh >/dev/null 2>&1 || { echo "未检测到 pvesh，这不是 PVE 节点，退出"; exit 1; }

# 安全基线：清除社区脚本常见的 smartctl/iostat setuid 残留（API 以 root 运行，无需 setuid）
for b in /usr/sbin/smartctl /usr/bin/iostat; do
    [ -e "$b" ] && chmod u-s,g-s "$b" 2>/dev/null || true
done

# IPMI 模式依赖 ipmitool：检测到 BMC 但缺 ipmitool 时尝试安装（失败则 applier 自动回落 sensors）
if [ -e /dev/ipmi0 ] && ! command -v ipmitool >/dev/null 2>&1; then
    echo "检测到 IPMI 设备，安装 ipmitool ..."
    apt-get install -y ipmitool || echo "ipmitool 安装失败，将回落到 lm-sensors 模式"
fi

# 部署 applier
install -m 0755 "$SRC_DIR/pve-status-panel.sh" "$BIN"

# 部署 APT 自愈 hook：pve-manager 升级会覆盖注入文件，每次 apt 后自动重打
cat > "$HOOK" <<EOF
// pve-status-panel —— pve-manager 升级会还原被注入的 Nodes.pm / pvemanagerlib.js，
// 此钩子在每次 apt/dpkg 操作后自动重打补丁（幂等），使面板不随升级消失。
DPkg::Post-Invoke { "[ -x $BIN ] && $BIN apply >/dev/null 2>&1 || true"; };
EOF

# 首次应用
"$BIN" apply

echo
echo "安装完成。请在浏览器按 Ctrl+Shift+R 强制刷新 PVE Web 界面查看节点「概览」卡片。"
echo "查看状态：$BIN status ；卸载/还原：sudo ./restore.sh （--full 彻底删除）"
