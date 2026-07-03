#!/usr/bin/env bash
# 还原/卸载 pve-status-panel
#   ./restore.sh          仅还原官方原版（摘除 hook + 还原两文件，保留 applier 与快照）
#   ./restore.sh --full   彻底卸载（另删除 applier 与 /usr/local/share 下快照）
set -euo pipefail

BIN=/usr/local/bin/pve-status-panel
HOOK=/etc/apt/apt.conf.d/99-pve-status-panel
STATE_DIR=/usr/local/share/pve-status-panel

[ "$(id -u)" = 0 ] || { echo "请以 root 运行"; exit 1; }

# 先摘 hook，避免还原后又被自愈重打
rm -f "$HOOK"

# 还原官方原版（applier 内部经 .orig 精确回退，含卡片高度；并停采集器、清 /run 数据）
if [ -x "$BIN" ]; then
    "$BIN" restore
else
    echo "未找到 $BIN，跳过还原（可能已卸载）"
fi

# 移除采集器 systemd 单元
systemctl disable --now pve-status-panel-collect.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/pve-status-panel-collect.timer /etc/systemd/system/pve-status-panel-collect.service
systemctl daemon-reload >/dev/null 2>&1 || true

if [ "${1:-}" = "--full" ]; then
    rm -f "$BIN"
    rm -rf "$STATE_DIR"
    echo "已彻底卸载（applier 与快照已删除）。"
else
    echo "已还原官方原版。applier 与快照保留（--full 可彻底删除）。浏览器 Ctrl+Shift+R 强刷。"
fi
