#!/bin/bash
# 备份她的全部身家。被她自己住的三个目录 + DSH 凭证与 profile 配置。
# 装在 /usr/local/bin/dsh-qq-backup.sh，由 /etc/cron.d/dsh-qq-backup 每天 04:30 触发。
set -euo pipefail

DEST=/var/backups/dsh-qq
KEEP=7
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${DEST}/dsh-qq-${STAMP}.tar.gz"

mkdir -p "${DEST}"
chmod 700 "${DEST}"

# 相对路径打包，解包时 cd / 即可，不依赖 tar 的 -P。
# 排除她 workspace 里三类「装得回来、备份无意义」的东西：
#   pylibs/            她自己 pip --target 装的 Pillow/zxingcpp（约 10 MB 的 .so）
#   backup/*.tar.gz    她自己打的备份包，套娃会让备份越滚越大
#   *.pyc / __pycache__ 编译缓存
tar -czf "${OUT}" \
  --exclude='var/lib/dsh-qq-agent/workspace/pylibs' \
  --exclude='var/lib/dsh-qq-agent/workspace/backup/*.tar.gz' \
  --exclude='*.pyc' \
  --exclude='__pycache__' \
  -C / \
  opt/dsh-qq-agent \
  var/lib/dsh-qq-agent \
  etc/dsh-qq-agent \
  root/.dsh/profiles/qq/package.json \
  root/.dsh/profiles/qq/cordis.patch.yml \
  root/.dsh/.credentials.yaml \
  2>/dev/null || true

if [ ! -s "${OUT}" ]; then
  echo "备份失败：${OUT} 不存在或为空"
  exit 1
fi

chmod 600 "${OUT}"

# 只留最近 KEEP 份
ls -1t "${DEST}"/dsh-qq-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "${old}"
done

printf '%s  %s  %s bytes\n' "${STAMP}" "$(basename "${OUT}")" "$(stat -c %s "${OUT}")"
ls -1t "${DEST}"/dsh-qq-*.tar.gz | wc -l
