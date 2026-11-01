#!/bin/bash
set -uo pipefail
set -e
cp /usr/local/bin/diary-automerge.sh "/usr/local/bin/diary-automerge.sh.bak-$(date +%Y%m%d%H%M%S)"
sed 's/\r$//' /tmp/diary-automerge.new.sh > /usr/local/bin/diary-automerge.sh
chmod +x /usr/local/bin/diary-automerge.sh
bash -n /usr/local/bin/diary-automerge.sh
echo "已安装："; ls -la /usr/local/bin/diary-automerge.sh /usr/local/bin/diary-automerge.sh.bak-* | tail -n 3
echo
echo "=== 立即跑一次（补 10-29 到 11-01 的稿子） ==="
/usr/local/bin/diary-automerge.sh
echo "退出码 $?"
echo
echo "=== 合并日志 ==="
tail -n 10 /var/log/dsh-qq-diary-merge.log
echo
echo "=== 日记目录现状 ==="
ls -la /opt/dsh-qq-agent/persona/diary | grep -v '\.bak\.' | tail -n 10
echo
echo "=== 两个待并目录 ==="
ls -la /var/lib/dsh-qq-agent/workspace/diary-pending /var/lib/dsh-qq-agent/workspace/persona-pending 2>&1 | tail -n 14
echo
echo "=== 新并入的每一天开头三行 ==="
for f in /opt/dsh-qq-agent/persona/diary/2026-10-2[9].md /opt/dsh-qq-agent/persona/diary/2026-1[01]-*.md; do
  [ -f "$f" ] || continue
  echo "--- $f ($(wc -c < "$f") 字节)"
  head -4 "$f"
done
