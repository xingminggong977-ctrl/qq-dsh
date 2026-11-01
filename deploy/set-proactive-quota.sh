#!/bin/bash
set -uo pipefail
cp /etc/dsh-qq-bridge/env "/etc/dsh-qq-bridge/env.bak-$(date +%Y%m%d%H%M%S)"
sed -i 's/^PROACTIVE_MAX_PER_DAY=.*/PROACTIVE_MAX_PER_DAY=4/; s/^PROACTIVE_MAX_ASKS_PER_DAY=.*/PROACTIVE_MAX_ASKS_PER_DAY=4/' /etc/dsh-qq-bridge/env
echo "=== 改后的三行 ==="
grep -E '^PROACTIVE_(MAX_PER_DAY|MAX_ASKS_PER_DAY|MIN_GAP_MS)=' /etc/dsh-qq-bridge/env
systemctl restart dsh-qq-bridge
sleep 3
systemctl is-active dsh-qq-bridge
echo "=== 启动日志里的闸门 ==="
journalctl -u dsh-qq-bridge --since '-1 min' --no-pager | grep -aE 'proactive gate armed|listening|napcat websocket' | tail -n 5
