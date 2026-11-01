#!/usr/bin/env bash
# 把仓库里已补齐的巡检脚本装到线上（线上还是只巡 3 个服务的旧版），然后实跑一轮看结果。
set -uo pipefail
set -e

D=/tmp/hostbin
mkdir -p "$D" /var/backups/dsh-qq-bin

echo "=== 1. 装前对比 ==="
for f in healthcheck.sh backup.sh alert.mjs napcat-watch.sh; do
  src=$D/$f
  [ -f "$src" ] || { echo "  !! 源缺失 $src"; continue; }
  case "$f" in
    healthcheck.sh) dst=/usr/local/bin/dsh-qq-healthcheck.sh ;;
    backup.sh)      dst=/usr/local/bin/dsh-qq-backup.sh ;;
    alert.mjs)      dst=/usr/local/bin/dsh-qq-alert.mjs ;;
    napcat-watch.sh) dst=/usr/local/bin/dsh-qq-napcat-watch.sh ;;
  esac
  if [ -f "$dst" ]; then
    a=$(sha256sum "$src" | awk '{print $1}')
    b=$(sha256sum "$dst" | awk '{print $1}')
    if [ "$a" = "$b" ]; then echo "  $f: 已一致（$(stat -c %s "$dst") 字节）"; else
      echo "  $f: 不同 —— 仓库 $(stat -c %s "$src") 字节 / 线上 $(stat -c %s "$dst") 字节"
      cp -a "$dst" "/var/backups/dsh-qq-bin/$(basename "$dst").bak-$(date +%Y%m%d-%H%M%S)"
    fi
  else
    echo "  $f: 线上不存在"
  fi
done

echo
echo "=== 2. 安装（备份到 /var/backups/dsh-qq-bin，不污染 /usr/local/bin）==="
mkdir -p /var/backups/dsh-qq-bin
for f in healthcheck.sh backup.sh alert.mjs napcat-watch.sh; do
  case "$f" in
    healthcheck.sh) n=dsh-qq-healthcheck.sh ;;
    backup.sh)      n=dsh-qq-backup.sh ;;
    alert.mjs)      n=dsh-qq-alert.mjs ;;
    napcat-watch.sh) n=dsh-qq-napcat-watch.sh ;;
  esac
  install -m 0755 -o root -g root "$D/$f" "/usr/local/bin/$n"
  echo "  已装 /usr/local/bin/$n ($(stat -c %s "/usr/local/bin/$n") 字节)"
done

echo
echo "=== 3. 确认新版巡检真的巡 5 个服务 ==="
grep -n 'for svc in' /usr/local/bin/dsh-qq-healthcheck.sh

echo
echo "=== 4. 实跑一轮巡检（看它现在报什么）==="
bash /usr/local/bin/dsh-qq-healthcheck.sh; echo "退出码=$?"

echo
echo "=== 5. /usr/local/bin 里是否留下 .bak 残留（check-host 要求为 0）==="
ls /usr/local/bin/ | grep -c '\.bak' || echo "0（干净）"
