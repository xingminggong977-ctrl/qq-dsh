#!/bin/bash
# 夜班安装器：把 nightly/systemd/ 里的单元装进 systemd，建好数据目录，做前置检查。
#
# 为什么单列一个脚本：这套东西由三个 timer 组成，手工装极容易只装一半（装了 digest 忘了 summary），
# 而「夜里没出活的真正原因」往往就是某个 timer 没 enable。所以装完必须打印将来的触发时刻。
# 卸载时只拆单元，产出（digest / stats / 提案 / 日志）一个都不删——那是她自己的记忆来源。
#
# 用法：install-nightly.sh [--status|--uninstall] [--user NAME] [--skip-token-check]
#   （不带参数 = 安装）
set -euo pipefail

# ---------- 路径常量 ----------
COMPONENT_DIR=/opt/dsh-qq-agent/nightly        # 夜班组件（别人写、部署在这里）
UNIT_DST=/etc/systemd/system                   # systemd 单元目录
STATE_DIR=/var/lib/dsh-qq-agent/nightly         # digest / stats / 清单
LOG_FILE=/var/log/dsh-qq-nightly.log           # 夜班日志
PROPOSAL_DIR=/opt/dsh-qq-agent/proposals       # 代码提案
BRIDGE_ENV=/etc/dsh-qq-bridge/env              # NODE_TOKEN 在这里
SYSTEMCTL=systemctl

# 本机预演钩子：只有显式 DSH_QQ_TEST_ROOTS=1 才允许改写上面这些路径与 systemctl 命令。
# 为什么加这道门：脚本里有 chown 和 rm，被一个残留环境变量改了路径就等于改错机器。
LOCAL_REHEARSAL=0
if [ "${DSH_QQ_TEST_ROOTS:-0}" = 1 ]; then
  LOCAL_REHEARSAL=1
  COMPONENT_DIR=${DSH_QQ_COMPONENT_DIR:-$COMPONENT_DIR}
  UNIT_DST=${DSH_QQ_UNIT_DST:-$UNIT_DST}
  STATE_DIR=${DSH_QQ_STATE_DIR:-$STATE_DIR}
  LOG_FILE=${DSH_QQ_LOG_FILE:-$LOG_FILE}
  PROPOSAL_DIR=${DSH_QQ_PROPOSAL_DIR:-$PROPOSAL_DIR}
  BRIDGE_ENV=${DSH_QQ_BRIDGE_ENV:-$BRIDGE_ENV}
  SYSTEMCTL=${DSH_QQ_SYSTEMCTL:-$SYSTEMCTL}
fi

readonly COMPONENT_DIR UNIT_DST STATE_DIR LOG_FILE PROPOSAL_DIR BRIDGE_ENV SYSTEMCTL LOCAL_REHEARSAL
readonly UNIT_SRC=$COMPONENT_DIR/systemd
readonly MANIFEST=$STATE_DIR/installed-units.txt
readonly UNIT_PREFIX=dsh-qq-nightly            # 单元名约定前缀，卸载时用来兜底找漏网的
readonly EXPECTED_TIMERS=3                     # 契约：03:00 挖矿、03:10 复盘、08:30 汇总
readonly STATUS_TAIL_LINES=20

OWNER_USER=root                                # 夜班进程以 root 跑（与 dsh-qq-agent 一致）
OWNER_GROUP=root
MODE=install
SKIP_TOKEN_CHECK=0

# ---------- 输出 ----------
say() { printf '%s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }
die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：install-nightly.sh [选项]

  （无参数）          安装 / 修复：装单元、建目录、前置检查、enable --now 所有 timer
  --status           只查状态：单元是否装了、timer 下次何时跑、日志尾部、产出目录
  --uninstall        卸载：disable --now 并删除单元；产出文件全部保留
  --user NAME        夜班的属主（默认 root）。若单元里写的 User= 与它不一致会告警
  --skip-token-check 跳过 NODE_TOKEN 检查（只有当夜班不用 bridge 的 NODE_TOKEN 时才该用）
  -h, --help         这个帮助
EOF
}

# ---------- 路径安全 ----------
require_root() {
  if [ "$LOCAL_REHEARSAL" = 1 ]; then
    say "（本机预演：跳过 root 检查）"
    return 0
  fi
  [ "$(id -u)" -eq 0 ] || die "要用 root 跑（当前 uid $(id -u)）"
}

# 删单元文件前必须过这一关：单元名白名单 + 解析后的绝对路径必须就是预期的那一个 + 不是目录不是软链。
# 为什么写得这么啰嗦：$UNIT_DST 在预演模式下会被改写，裸的 rm -f "$UNIT_DST/$name" 会跟着跑偏。
safe_remove_unit() {
  local name="$1" path resolved
  case "$name" in
    "" | *[!A-Za-z0-9:_.@-]*) die "拒绝：单元名里有可疑字符：$name" ;;
  esac
  case "$name" in
    *.service | *.timer) ;;
    *) die "拒绝：只删 .service/.timer，收到 $name" ;;
  esac

  path="$UNIT_DST/$name"
  resolved=$(realpath -m -- "$path") || die "realpath 失败：$path"
  [ "$resolved" = "$path" ] || die "拒绝：$path 解析后是 $resolved，与预期不符"
  # 写成 if 而不是 [ ] && die：后者在条件为假时会把函数返回码变成 1，调用方 set -e 会直接退出。
  if [ -d "$resolved" ]; then
    die "拒绝：$resolved 是目录"
  fi
  if [ -L "$resolved" ]; then
    die "拒绝：$resolved 是软链，请手工处理"
  fi
  if [ -e "$resolved" ]; then
    rm -f -- "$resolved"
    say "  已删除 $resolved"
  else
    say "  不存在，跳过 $resolved"
  fi
}

# ---------- 前置检查 ----------
# 只回报「读到 / 没读到」。值只进变量，绝不 echo——这段输出会被贴进聊天和日志。
check_node_token() {
  if [ ! -r "$BRIDGE_ENV" ]; then
    say "NODE_TOKEN：没读到（$BRIDGE_ENV 不存在或不可读）"
    return 1
  fi
  local value
  value=$(sed -n 's/^NODE_TOKEN=//p' "$BRIDGE_ENV" | tail -n 1)
  if [ -z "$value" ]; then
    say "NODE_TOKEN：没读到（$BRIDGE_ENV 里没有非空的 NODE_TOKEN 行）"
    return 1
  fi
  case "$value" in
    REPLACE_WITH_*)
      say "NODE_TOKEN：没读到（还是 env.example 的模板占位值）"
      return 1
      ;;
  esac
  say "NODE_TOKEN：读到"
  return 0
}

list_files_by_ext() {
  local dir="$1" ext="$2" f
  for f in "$dir"/*."$ext"; do
    [ -e "$f" ] || continue
    basename -- "$f"
  done | sort -u
}

# ---------- 目录与属主 ----------
make_dir() {
  mkdir -p -- "$1"
  chmod 0755 -- "$1"
  if [ "$LOCAL_REHEARSAL" = 1 ]; then
    return 0
  fi
  chown "$OWNER_USER:$OWNER_GROUP" -- "$1"
}

make_log_file() {
  [ -e "$LOG_FILE" ] || : >"$LOG_FILE"
  chmod 0640 -- "$LOG_FILE"
  if [ "$LOCAL_REHEARSAL" = 1 ]; then
    return 0
  fi
  chown "$OWNER_USER:$OWNER_GROUP" -- "$LOG_FILE"
}

copy_unit() {
  if [ "$LOCAL_REHEARSAL" = 1 ]; then
    install -m 0644 -- "$1" "$2"
    return 0
  fi
  install -m 0644 -o root -g root -- "$1" "$2"
}

# ---------- 安装 ----------
do_install() {
  require_root
  [ "$UNIT_DST" != "/" ] || die "UNIT_DST 不能是 /"

  section "0. 目标"
  say "组件目录：$COMPONENT_DIR"
  say "单元来源：$UNIT_SRC"
  say "单元目录：$UNIT_DST"
  say "状态目录：$STATE_DIR"
  say "日志：$LOG_FILE"
  say "提案目录：$PROPOSAL_DIR"
  say "属主：$OWNER_USER:$OWNER_GROUP"
  if [ "$LOCAL_REHEARSAL" = 1 ]; then
    say "！！本机预演模式：不 chown、不按 root 校验属主，systemctl=$SYSTEMCTL"
  fi

  section "1. 前置检查"
  command -v node >/dev/null 2>&1 || die "PATH 里没有 node（夜班用 node 跑）"
  say "node：$(node --version)"
  [ -d "$UNIT_SRC" ] || die "找不到单元目录 $UNIT_SRC（夜班组件还没铺上来？）"
  local timers units timer_count
  timers=$(list_files_by_ext "$UNIT_SRC" timer)
  [ -n "$timers" ] || die "$UNIT_SRC 里没有 .timer，装不了"
  timer_count=$(printf '%s\n' "$timers" | wc -l | tr -d ' ')
  say "timer 数量：$timer_count（契约：$EXPECTED_TIMERS 个 —— 03:00 挖矿 / 03:10 复盘 / 08:30 汇总）"
  if [ "$timer_count" -ne "$EXPECTED_TIMERS" ]; then
    say "警告：数量与契约不一致，仍继续；装完请用 --status 核对触发时刻"
  fi
  if [ "$SKIP_TOKEN_CHECK" = 1 ]; then
    say "NODE_TOKEN：跳过检查（--skip-token-check）"
  else
    check_node_token || die "NODE_TOKEN 读不到；先修 $BRIDGE_ENV，或确认夜班不用它再加 --skip-token-check"
  fi

  section "2. 目录与属主"
  make_dir "$STATE_DIR"
  say "  $STATE_DIR"
  make_dir "$PROPOSAL_DIR"
  say "  $PROPOSAL_DIR"
  make_log_file
  say "  $LOG_FILE"

  section "3. 装单元文件"
  units=$(printf '%s\n%s\n' "$timers" "$(list_files_by_ext "$UNIT_SRC" service)" | sed '/^$/d' | sort -u)
  local name
  while IFS= read -r name; do
    case "$name" in
      "" | *[!A-Za-z0-9:_.@-]*) die "拒绝：单元文件名里有可疑字符：$name" ;;
    esac
    copy_unit "$UNIT_SRC/$name" "$UNIT_DST/$name"
    say "  $name"
  done <<<"$units"
  # 单元里写死的 User= 和我们 chown 出来的属主必须一致，否则夜里写文件会 Permission denied。
  if [ "$OWNER_USER" != "root" ]; then
    local svc found=0
    while IFS= read -r svc; do
      case "$svc" in
        *.service) ;;
        *) continue ;;
      esac
      if grep -q "^User=$OWNER_USER\$" "$UNIT_DST/$svc" 2>/dev/null; then
        found=1
      fi
    done < <(printf '%s\n' "$units")
    if [ "$found" -eq 0 ]; then
      say "警告：单元里没有 User=$OWNER_USER，但产出目录已 chown 给 $OWNER_USER；两者对不上夜里会写不进去"
    fi
  fi

  section "4. daemon-reload"
  "$SYSTEMCTL" daemon-reload
  say "已 reload"

  section "5. enable --now（幂等：已 enabled/active 的只报状态）"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if "$SYSTEMCTL" is-enabled --quiet "$name"; then
      say "  $name 已 enabled，跳过 enable"
    else
      "$SYSTEMCTL" enable "$name"
      say "  $name 已 enable"
    fi
    if "$SYSTEMCTL" is-active --quiet "$name"; then
      say "  $name 已 active，跳过 start"
    else
      "$SYSTEMCTL" start "$name"
      say "  $name 已 start"
    fi
  done <<<"$timers"

  section "6. 记下装了哪些单元（卸载靠它）"
  printf '%s\n' "$units" >"$MANIFEST"
  say "  $MANIFEST"

  section "7. 未来触发时刻"
  show_timers

  section "8. 日志尾部"
  tail -n "$STATUS_TAIL_LINES" "$LOG_FILE" 2>/dev/null || say "（$LOG_FILE 还是空的，正常）"

  say ""
  say "装完了。下一步：systemctl list-timers | grep nightly，然后等 03:00 或手工 systemctl start <挖矿 timer 对应的 service>"
}

show_timers() {
  # list-timers 在没有匹配时返回 0 但输出空，grep 会以 1 退出，所以这里必须吞掉失败。
  "$SYSTEMCTL" list-timers --all --no-pager 2>/dev/null | grep -i nightly || say "（list-timers 没有匹配到 nightly，检查单元名是否以 $UNIT_PREFIX 开头）"
}

# ---------- 卸载 ----------
do_uninstall() {
  require_root
  section "1. 收集要拆的单元"
  local list_file
  list_file=$(mktemp "${TMPDIR:-/tmp}/dsh-qq-nightly-units.XXXXXX")
  if [ -f "$MANIFEST" ]; then
    say "读清单：$MANIFEST"
    cat -- "$MANIFEST" >>"$list_file"
  fi
  local f
  for f in "$UNIT_DST/$UNIT_PREFIX"*; do
    [ -e "$f" ] || continue
    basename -- "$f" >>"$list_file"
  done
  sort -u -o "$list_file" "$list_file"
  if [ ! -s "$list_file" ]; then
    say "没有找到任何 $UNIT_PREFIX* 单元，没什么可卸的"
    rm -f -- "$list_file"
    return 0
  fi
  sed 's/^/  /' "$list_file"

  section "2. disable --now 所有 timer"
  local name
  while IFS= read -r name; do
    case "$name" in
      "" | *.service) continue ;; # 只对 timer 做 disable --now；oneshot service 由 timer 带起
    esac
    if "$SYSTEMCTL" is-enabled --quiet "$name" || "$SYSTEMCTL" is-active --quiet "$name"; then
      "$SYSTEMCTL" disable --now "$name"
      say "  $name 已停用"
    else
      say "  $name 本来就没在跑"
    fi
  done <"$list_file"

  section "3. 删除单元文件（逐个校验路径）"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    safe_remove_unit "$name"
  done <"$list_file"
  rm -f -- "$list_file"

  section "4. daemon-reload"
  "$SYSTEMCTL" daemon-reload
  "$SYSTEMCTL" reset-failed 2>/dev/null || true
  say "已 reload"

  section "5. 保留的产出（卸载不删）"
  say "  $STATE_DIR      digest/stats/清单"
  say "  $PROPOSAL_DIR   代码提案"
  say "  $LOG_FILE       夜班日志"
  say "想连产出一起清掉时手工来，别写进脚本：rm -rf 不该出现在一条命令里"
}

# ---------- 状态 ----------
state_of() {
  local unit="$1" verb="$2" out
  out=$("$SYSTEMCTL" "$verb" "$unit" 2>/dev/null) || true
  printf '%s' "${out:-未装}"
}

do_status() {
  section "0. 路径"
  say "组件目录：$COMPONENT_DIR"
  say "单元来源：$UNIT_SRC"
  if [ "$LOCAL_REHEARSAL" = 1 ]; then
    say "！！本机预演模式：systemctl=$SYSTEMCTL"
  fi

  section "1. 单元（装了没有 / enabled / active）"
  local list_file
  list_file=$(mktemp "${TMPDIR:-/tmp}/dsh-qq-nightly-status.XXXXXX")
  if [ -f "$MANIFEST" ]; then
    cat -- "$MANIFEST" >>"$list_file"
  fi
  local f
  for f in "$UNIT_DST/$UNIT_PREFIX"*; do
    [ -e "$f" ] || continue
    basename -- "$f" >>"$list_file"
  done
  sort -u -o "$list_file" "$list_file"
  if [ -s "$list_file" ]; then
    local name
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf '  %-34s enabled=%-10s active=%s\n' "$name" "$(state_of "$name" is-enabled)" "$(state_of "$name" is-active)"
    done <"$list_file"
  else
    say "  （没装：清单和 $UNIT_DST/$UNIT_PREFIX* 都是空的）"
  fi
  rm -f -- "$list_file"

  section "2. list-timers"
  show_timers

  section "3. 目录与属主"
  local path
  for path in "$STATE_DIR" "$PROPOSAL_DIR" "$LOG_FILE"; do
    if [ -e "$path" ]; then
      ls -ld -- "$path"
    else
      say "  缺：$path（跑一次安装）"
    fi
  done

  section "4. 夜班日志尾部"
  if [ -f "$LOG_FILE" ]; then
    tail -n "$STATUS_TAIL_LINES" "$LOG_FILE"
  else
    say "  （没有 $LOG_FILE）"
  fi

  section "5. 最近的产出"
  # head 读几行就走会杀掉 ls（SIGPIPE），pipefail 下这条管线会以 141 结束，必须吞掉。
  if [ -d "$STATE_DIR" ]; then
    ls -lt -- "$STATE_DIR" 2>/dev/null | head -n 8 || true
  fi
  if [ -d "$PROPOSAL_DIR" ]; then
    ls -lt -- "$PROPOSAL_DIR" | head -n 8
  else
    say "  提案目录还不存在（夜里没产出提案，或者没装）"
  fi
}

# ---------- 入口 ----------
main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status) MODE=status ;;
      --uninstall) MODE=uninstall ;;
      --user)
        [ "$#" -ge 2 ] || die "--user 后面要跟用户名"
        OWNER_USER="$2"
        OWNER_GROUP="$2"
        shift
        ;;
      --skip-token-check) SKIP_TOKEN_CHECK=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "不认识的参数：$1"
        ;;
    esac
    shift
  done

  case "$MODE" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) do_status ;;
  esac
}

main "$@"
