#!/bin/bash
# 装她那份巡检（带去抖与宽限期），但先把她没有的那段「GitHub 令牌快过期」补回去。
# 直接跑她的安装脚本会把我之前加的令牌提醒装没——功能回退不该发生在"修 bug"的名义下。
set -euo pipefail

SRC=/var/lib/dsh-qq-agent/workspace/patches/healthcheck.sh
DST=/usr/local/bin/dsh-qq-healthcheck.sh
BAK=$DST.bak-$(date +%Y%m%d-%H%M%S)
TMP=/tmp/hc-merged.sh

[ "$(id -u)" -eq 0 ] || { echo "要用 root 跑"; exit 1; }
[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }

cp -a "$DST" "$BAK"
cp "$SRC" "$TMP"

if ! grep -q 'token-reminded' "$TMP"; then
python3 - "$TMP" <<'PY'
import sys

path = sys.argv[1]
block = '''# GitHub 令牌 90 天过期。从第 80 天起，每天提醒一次（同一天只提醒一次）。
TOKEN=/etc/dsh-qq-agent/github-token
STAMP=/var/lib/dsh-qq-agent/token-reminded
if [ -f "$TOKEN" ]; then
  age_days=$(( ( $(date +%s) - $(stat -c %Y "$TOKEN") ) / 86400 ))
  if [ "$age_days" -ge 80 ] && [ "$(cat "$STAMP" 2>/dev/null || echo -)" != "$(date +%F)" ]; then
    date +%F > "$STAMP"
    echo "$(date -Is) 令牌已 ${age_days} 天" >> "$LOG"
    "$PUSH" "GitHub 令牌该换了" "异地备份用的令牌已经 ${age_days} 天，90 天过期。去 GitHub 生成新的，替换 /etc/dsh-qq-agent/github-token。" >> "$LOG" 2>&1 || true
  fi
fi

'''
text = open(path, encoding='utf-8').read()
anchor = '# 日志按行数轮转'
index = text.index(anchor)
open(path, 'w', encoding='utf-8').write(text[:index] + block + text[index:])
print('已补回令牌提醒段')
PY
else
  echo "新脚本已带令牌提醒段，不重复插入"
fi

bash -n "$TMP"
install -m 0755 "$TMP" "$DST"
echo "已安装 $DST（旧版备份 $BAK）"
echo "令牌提醒段命中 $(grep -c 'token-reminded' "$DST") 处，去抖段命中 $(grep -c 'STRIKE' "$DST") 处"
systemctl start dsh-qq-healthcheck.service
echo "--- 日志末尾 ---"
tail -n 3 /var/log/dsh-qq-healthcheck.log
