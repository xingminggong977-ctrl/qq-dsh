#!/bin/bash
set -uo pipefail
P=/root/.dsh/profiles/qq/cordis.patch.yml

busy=$(node -e '
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync("/var/lib/dsh-qq-bridge/queue.db");
const row = db.prepare("select count(*) c from tasks where status not in (\"done\",\"failed\")").get();
console.log(row.c);
' 2>/dev/null || echo '?')
echo "未结算任务数：$busy"

cp "$P" "$P.bak-tto-$(date +%Y%m%d%H%M%S)"
sed -i 's/^\(\s*\)turnTimeoutMs: 180000/\1turnTimeoutMs: 240000/' "$P"
echo "=== 改后 ==="
grep -n 'turnTimeoutMs' "$P"

if [ "$busy" != "0" ]; then
  echo "有回合在跑（$busy），这次不重启；配置改动等下次重启生效"
  exit 0
fi

systemctl restart dsh-qq-agent
sleep 4
systemctl is-active dsh-qq-agent
echo "=== 重启后横幅 ==="
journalctl -u dsh-qq-agent --since '-1 min' --no-pager | grep -aE 'polling|rotation|tiering|registered remind' | tail -n 6
