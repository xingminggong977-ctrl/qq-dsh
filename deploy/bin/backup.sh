#!/bin/bash
# 备份她的一切：数据、配置、凭据、队列、单元、主机脚本。
# 装在 /usr/local/bin/dsh-qq-backup.sh，由 /etc/cron.d/dsh-qq-backup 每天 08:00 触发。
#
# 2026-10-27 重写（换机时暴露的两个问题）：
#   1) 旧版只备了三个数据目录，漏掉 /etc/dsh-qq-bridge/env、queue.db、NapCat 配置、
#      unit 与 /usr/local/bin 脚本 —— 真出事时照着旧包还原，她连 QQ 都登不回来。
#   2) 旧版 `tar … 2>/dev/null || true`：任意路径读失败仍然报成功，包是残的却没人知道。
#      所以现在先校验清单、再打包、最后验包，任何一步不对就失败退出。
#
# 包里含 token 与模型 key（600 root），与源文件同权限，不要外传。
set -euo pipefail

DEST=/var/backups/dsh-qq
KEEP=7
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${DEST}/dsh-qq-${STAMP}.tar.gz"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${DEST}"
chmod 700 "${DEST}"

# 少一样就不算备份成功——宁可今天没有备份，也不要一份「看起来成功」的残包。
REQUIRED=(
  opt/dsh-qq-agent
  var/lib/dsh-qq-agent
  etc/dsh-qq-agent/env
  etc/dsh-qq-bridge/env
  etc/dsh-qq-nightly/env
  var/lib/dsh-qq-bridge/queue.db
  opt/napcat/napcat/config
  opt/napcat/launcher.sh
  root/.dsh/.credentials.yaml
  root/.dsh/llm-deepseek
  root/.dsh/profiles/qq/cordis.patch.yml
  root/.dsh/profiles/qq/package.json
)
OPTIONAL=(
  etc/cron.d/dsh-qq-backup
  etc/cron.d/dsh-qq-diary-merge
  etc/cron.d/dsh-qq-github-backup
  etc/logrotate.d/dsh-qq
  etc/sysctl.d/99-dsh-qq.conf
  usr/local/bin/dsh-qq-alert.mjs
  usr/local/bin/dsh-qq-backup.sh
  usr/local/bin/dsh-qq-healthcheck.sh
  usr/local/bin/dsh-qq-napcat-watch.sh
  usr/local/bin/dsh-qq-post-migration-audit.sh
  usr/local/bin/diary-automerge.sh
  usr/local/bin/backup-to-github.sh
  usr/local/bin/push-notify.sh
  # 下面 5 个手工运维工具原先只活在旧机磁盘上（2026-10-27 比对才发现没进仓库）。
  # 名单与 deploy/install-host-scripts.sh 的 MANIFEST 必须同步，否则又会漏。
  usr/local/bin/check-task
  usr/local/bin/recent-tasks
  usr/local/bin/enqueue-owner-text.sh
  usr/local/bin/seed-corrections.sh
  usr/local/bin/preview-corrections.sh
)

missing=()
for p in "${REQUIRED[@]}"; do
  [ -e "/$p" ] || missing+=("$p")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "备份失败：以下必备路径不存在"
  printf '  /%s\n' "${missing[@]}"
  exit 1
fi

MEMBERS=("${REQUIRED[@]}")
skipped=()
for p in "${OPTIONAL[@]}"; do
  if [ -e "/$p" ]; then MEMBERS+=("$p"); else skipped+=("$p"); fi
done

# systemd 单元按通配收集（数量会变，写死在清单里迟早漏）。
while IFS= read -r f; do
  [ -n "$f" ] && MEMBERS+=("${f#/}")
done < <(ls -1 /etc/systemd/system/dsh-qq-*.service /etc/systemd/system/dsh-qq-*.timer /etc/systemd/system/napcat.service 2>/dev/null)

# queue.db 用 SQLite 在线备份 API 取一致快照：bridge 一直在写，直接拷会拿到半页数据，
# 而 -wal 里未合并的部分会被静默丢掉。
SNAP="${STAGE}/var/lib/dsh-qq-bridge"
mkdir -p "${SNAP}"
python3 - "${SNAP}/queue.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect('file:/var/lib/dsh-qq-bridge/queue.db?mode=ro', uri=True)
dst = sqlite3.connect(sys.argv[1])
src.backup(dst)
dst.close()
src.close()
chk = sqlite3.connect(sys.argv[1])
res = chk.execute('PRAGMA integrity_check').fetchone()[0]
chk.close()
if res != 'ok':
    sys.exit('queue 快照 integrity_check 未通过：' + str(res))
PY

tar -czf "${OUT}" \
  --exclude='var/lib/dsh-qq-agent/workspace/pylibs' \
  --exclude='var/lib/dsh-qq-agent/workspace/backup/*.tar.gz' \
  --exclude='*.pyc' \
  --exclude='__pycache__' \
  --exclude='var/lib/dsh-qq-bridge/queue.db-wal' \
  --exclude='var/lib/dsh-qq-bridge/queue.db-shm' \
  -C / "${MEMBERS[@]}" \
  -C "${STAGE}" var/lib/dsh-qq-bridge/queue.db \
  2>"${STAGE}/tar.err"
if [ -s "${STAGE}/tar.err" ]; then
  echo "备份失败：tar 报了 $(wc -l <"${STAGE}/tar.err") 行问题"
  head -5 "${STAGE}/tar.err"
  rm -f "${OUT}"
  exit 1
fi

# 验包：能解压、成员数合理、关键路径确实在里面。
gzip -t "${OUT}"
tar -tzf "${OUT}" >"${STAGE}/list.txt"
for key in opt/dsh-qq-agent/audit var/lib/dsh-qq-agent etc/dsh-qq-bridge/env \
           var/lib/dsh-qq-bridge/queue.db root/.dsh/.credentials.yaml \
           opt/napcat/napcat/config; do
  if ! grep -q "^${key}" "${STAGE}/list.txt"; then
    echo "备份失败：包里没有 ${key}"
    rm -f "${OUT}"
    exit 1
  fi
done

chmod 600 "${OUT}"

# 只留最近 KEEP 份
ls -1t "${DEST}"/dsh-qq-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "${old}"
done

printf '%s  %s  %s bytes  %s members\n' \
  "${STAMP}" "$(basename "${OUT}")" "$(stat -c %s "${OUT}")" "$(wc -l <"${STAGE}/list.txt")"
[ "${#skipped[@]}" -gt 0 ] && printf '跳过（不存在）: %s\n' "${skipped[*]}"
ls -1t "${DEST}"/dsh-qq-*.tar.gz | wc -l
exit 0
