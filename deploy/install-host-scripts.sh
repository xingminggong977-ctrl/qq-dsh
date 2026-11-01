#!/usr/bin/env bash
# 把 deploy/bin/ 下的主机脚本装到 /usr/local/bin/dsh-qq-*。
#
# 为什么要这个脚本：这几个脚本长期只存在于服务器上，仓库里是旧的（
# deploy/dsh-qq-healthcheck.sh 停在 3896 字节，线上已是 5283 字节），
# 换机器时没有任何办法把它恢复出来。装一遍就把仓库变成权威副本。
#
# 两个刻意的设计：
#   1. 默认 dry-run。要真装必须显式 --apply，和 harden-host.sh 保持一致。
#   2. 备份放到 /var/backups/dsh-qq-bin/，不放 /usr/local/bin/。
#      线上历史上就在 bin 目录里堆过 .bak-* 残留（dsh-qq-healthcheck.sh.bak-20261026-095001），
#      而 check-host.sh 第 6 项专门检查这个目录里 .bak 残留必须为 0。
#      把新备份写进同一个目录，等于让每次安装都把自检搞红。
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR=$SELF_DIR/bin
# 两个目录允许用环境变量覆盖，唯一目的是能在不碰 /usr/local/bin 的前提下，
# 拿服务器上文件的真实字节数把"备份后覆盖"那条分支跑一遍。
TARGET_DIR=${TARGET_DIR:-/usr/local/bin}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/dsh-qq-bin}

DRY_RUN=1
STAMP=$(date +%Y%m%d-%H%M%S)

# 源文件:安装后的名字。显式清单而不是通配，避免把 bin/ 里的说明文档也装上去。
MANIFEST=(
  "healthcheck.sh:dsh-qq-healthcheck.sh"
  "backup.sh:dsh-qq-backup.sh"
  "alert.mjs:dsh-qq-alert.mjs"
  "napcat-watch.sh:dsh-qq-napcat-watch.sh"
  "backup-to-github.sh:backup-to-github.sh"
  "push-notify.sh:push-notify.sh"
  "diary-automerge.sh:diary-automerge.sh"
  "post-migration-audit.sh:dsh-qq-post-migration-audit.sh"
  "check-task:check-task"
  "recent-tasks:recent-tasks"
  "enqueue-owner-text.sh:enqueue-owner-text.sh"
  "seed-corrections.sh:seed-corrections.sh"
  "preview-corrections.sh:preview-corrections.sh"
)

usage() {
  cat <<'EOF'
用法: install-host-scripts.sh [--dry-run|--apply]

  --dry-run   只打印将要做什么（默认）
  --apply     真正安装到 /usr/local/bin
  -h, --help  显示本帮助
EOF
}

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# 装之前先验语法：宁可不装，也不要把跑不起来的脚本放上生产机。
syntax_check() {
  local f=$1
  case "$f" in
    *.sh)
      if bash -n "$f"; then
        echo "    bash -n 通过"
      else
        echo "    !! bash -n 失败：$f" >&2
        return 1
      fi
      ;;
    *.mjs|*.js)
      if ! command -v node >/dev/null 2>&1; then
        echo "    .. 本机没有 node，跳过 node --check"
        return 0
      fi
      if node --check "$f" 2>/dev/null; then
        echo "    node --check 通过"
      else
        echo "    !! node --check 失败：$f" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) DRY_RUN=0 ;;
      --dry-run|-n) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  echo "=============================================="
  echo " 安装主机脚本  host=$(hostname)  $(date -Is)"
  echo " 源目录: $BIN_DIR"
  echo " 目标:   $TARGET_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo " 模式=dry-run（只打印，不改动任何东西）；加 --apply 执行"
  else
    echo " 模式=APPLY（会覆盖线上的脚本）"
  fi
  echo "=============================================="

  # 这个脚本在服务器上跑才有意义：TARGET_DIR=/usr/local/bin 在那边才是真目录。
  # 在 Windows/Git Bash 上跑属于"预演"，只能验语法，比对的是本地一个不存在的路径，
  # 所以下面那些"首次安装"不代表线上真的没装——不说清楚会读成假证据。
  if [ "$(uname -s)" != Linux ]; then
    echo
    echo " !! 当前主机 $(uname -s)，不是 Linux：这是本地预演。"
    echo "    只能验证语法；与已装版本的比对要在服务器上跑才有效。"
    echo "    机器上已有的 /usr/local/bin/dsh-qq-* 不会被这里读到。"
  fi

  if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "!! --apply 需要 root：sudo bash $0 --apply" >&2
    exit 1
  fi

  local installed=0 skipped=0 backed=0 entry src name dst
  for entry in "${MANIFEST[@]}"; do
    src=$BIN_DIR/${entry%%:*}
    name=${entry##*:}
    dst=$TARGET_DIR/$name

    echo
    echo "-- $name"

    if [ ! -f "$src" ]; then
      echo "   !! 源文件不存在：$src" >&2
      exit 1
    fi
    syntax_check "$src" || exit 1

    if [ -f "$dst" ]; then
      if [ "$(sha256_of "$src")" = "$(sha256_of "$dst")" ]; then
        echo "   与已装版本一致，跳过（$(stat -c %s "$dst") 字节）"
        skipped=$((skipped + 1))
        continue
      fi
      # 带上 sha 前 8 位：只报字节数时会出现"1500 -> 1500"这种看着像坏掉的输出，
      # 实际是同尺寸不同内容。
      echo "   已装版本不同：$(stat -c %s "$dst") 字节 [$(sha256_of "$dst" | cut -c1-8)] -> $(stat -c %s "$src") 字节 [$(sha256_of "$src" | cut -c1-8)]"
      local bak="$BACKUP_DIR/$name.bak-$STAMP"
      if [ "$DRY_RUN" -eq 1 ]; then
        printf '   [dry-run] mkdir -p %s && cp -p %s %s\n' "$BACKUP_DIR" "$dst" "$bak"
      else
        mkdir -p "$BACKUP_DIR"
        cp -p "$dst" "$bak"
        echo "   已备份旧版：$bak"
      fi
      backed=$((backed + 1))
    else
      echo "   目标位置还没有 $name，将首次安装"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      printf '   [dry-run] install -m 0755 -o root -g root %s %s\n' "$src" "$dst"
    else
      install -m 0755 -o root -g root "$src" "$dst"
      echo "   已安装：$dst（$(stat -c %s "$dst") 字节，$(stat -c %A "$dst")）"
    fi
    installed=$((installed + 1))
  done

  echo
  echo "=============================================="
  if [ "$DRY_RUN" -eq 1 ]; then
    echo " dry-run 结束：将安装 $installed 个、备份 $backed 个、跳过 $skipped 个。"
    echo " 真正落地：sudo bash $0 --apply"
  else
    echo " 完成：安装 $installed 个、备份 $backed 个、跳过 $skipped 个。"
    echo " 不需要重启任何服务：healthcheck 由 dsh-qq-healthcheck.timer 每轮重新执行该文件，"
    echo " 下一轮就吃到新版本。"
  fi
  echo "=============================================="
}

main "$@"
