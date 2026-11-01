#!/bin/bash
set -uo pipefail
sed -i 's/\r$//' /tmp/dsh-qq-diary-merge.cron
cp /etc/cron.d/dsh-qq-diary-merge "/etc/cron.d/dsh-qq-diary-merge.bak-$(date +%Y%m%d%H%M%S)"
install -m 0644 -o root -g root /tmp/dsh-qq-diary-merge.cron /etc/cron.d/dsh-qq-diary-merge
echo "=== 现在的 cron 文件 ==="
cat /etc/cron.d/dsh-qq-diary-merge
echo
echo "=== cron 服务状态 ==="
systemctl is-active cron 2>/dev/null || systemctl is-active crond 2>/dev/null
echo
echo "=== 下一次触发时间（cron 日志风格自检） ==="
python3 - <<'EOF'
from croniter import croniter
EOF
echo "(没有 croniter 就跳过上面这行)"
echo
echo "=== 语法体检：cron 有没有报错 ==="
journalctl -u cron --since '-5 min' --no-pager 2>/dev/null | grep -aiE 'diary-merge|error|bad' | tail -n 5
echo "(以上为空即无报错)"
