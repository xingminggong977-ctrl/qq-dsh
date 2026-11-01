#!/bin/bash
# 内核僵死看门狗：QQ NT 的 sendMsg 监听器会周期性失效（EventChecker Failed），
# 表现为「NapCat 说自己在线，但任何消息都投递不出去，retcode 1200」——
# 入站也会一起停，主人看到的现象就是"她不理我"。
# 2026-10-26 当天发生了两次：11:23 与 22:46，间隔约 11 小时。
#
# 处置只有一条路：重启 napcat。但重启有两个坑，本脚本就是为绕开它们而写的：
#   1. 重启会走登录流程。票据新鲜时能快速登录（22:53 实测成功）；
#      票据过期就得人扫码（22:47 实测失败）。
#   2. 重启会打断正在进行的登录。22:53 我自己就干过：主人 22:51 扫了码，
#      我 22:53 又重启，把那次成功登录打断了。
#      所以动手前必须先读日志，确认当前不在登录流程里。
#
# 设计：把"重启"与"复核"拆成两次运行，单次运行不超过 15 秒，
# 这样 3 分钟一次的 timer 不会堆积。
set -uo pipefail

LOG=/var/log/dsh-qq-napcat-watch.log
STATE_DIR=/var/lib/dsh-qq-agent
RESTART_AT=$STATE_DIR/napcat-watch.restart-at
LAST_ALERT=$STATE_DIR/napcat-watch.last-alert
ALERT=/usr/local/bin/dsh-qq-alert.mjs
PUSH=/usr/local/bin/push-notify.sh
ENVF=/etc/dsh-qq-agent/env

WINDOW_MIN=${WINDOW_MIN:-10}     # 统计窗口
THRESHOLD=${THRESHOLD:-3}        # 窗口内出现几次才判定僵死
COOLDOWN=${COOLDOWN:-1800}       # 两次重启至少间隔 30 分钟，避免抖动里连环重启
VERIFY_DEADLINE=${VERIFY_DEADLINE:-180}  # 重启后 3 分钟内仍发不出去，就认定需要人介入
ALERT_GAP=${ALERT_GAP:-3600}     # 同类微信告警 1 小时内最多一次
# 1 = 只判定不重启（用于用真实日志验证判定逻辑，不碰线上）
DRY_RUN=${DRY_RUN:-0}

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }
now() { date +%s; }

push_once() {
  local title=$1 body=$2 last=0
  [ -f "$LAST_ALERT" ] && last=$(cat "$LAST_ALERT" 2>/dev/null || echo 0)
  [ -n "${last:-}" ] || last=0
  if [ $(( $(now) - last )) -lt "$ALERT_GAP" ]; then
    log "微信告警被限流（1 小时内已发过）：$title"
    return 0
  fi
  if [ -x "$PUSH" ]; then
    "$PUSH" "$title" "$body" >>"$LOG" 2>&1 && now >"$LAST_ALERT" && log "已推微信：$title" || log "微信推送失败：$title"
  else
    log "微信推送脚本 $PUSH 不存在：$title"
  fi
}

# 近 N 分钟日志（去 ANSI）
recent() { journalctl -u napcat --since "-${1}min" --no-pager -o cat 2>/dev/null | sed -r 's/\x1b\[[0-9;]*m//g'; }

# 登录流程进行中：扫码已被受理，或正在快速登录，或还在等扫码。
login_in_flight() {
  recent 8 | grep -aqE '二维码已被扫描|正在快速登录' && return 0
  # 等扫码：最近 8 分钟出过二维码，且之后没有登录成功
  if recent 8 | grep -aq '请扫描下面的二维码'; then
    recent 8 | grep -aqE '登录成功|已上线' && return 1
    return 0
  fi
  return 1
}

# 真发一条验证发送链路。成功返回 0；同时主人会收到这条消息本身。
send_probe() {
  local tok
  tok=$(grep -E '^NAPCAT_ACCESS_TOKEN=' "$ENVF" 2>/dev/null | cut -d= -f2-)
  [ -n "${tok:-}" ] || tok=$(grep -E '^NAPCAT_TOKEN=' "$ENVF" 2>/dev/null | cut -d= -f2-)
  NAPCAT_TOKEN="$tok" timeout 20 node "$ALERT" \
    "（看门狗）QQ 内核又僵死了，我已重启 NapCat，正在验证发送链路。这条能收到说明已恢复。" \
    >>"$LOG" 2>&1
}

main() {
  mkdir -p "$STATE_DIR"

  # ---------- 阶段二：上次刚重启过，先复核是否真的恢复了 ----------
  if [ -f "$RESTART_AT" ]; then
    local at elapsed
    at=$(cat "$RESTART_AT" 2>/dev/null || echo 0)
    [ -n "${at:-}" ] || at=0
    elapsed=$(( $(now) - at ))
    if [ "$elapsed" -lt "$VERIFY_DEADLINE" ]; then
      if send_probe; then
        log "复核通过：发送链路已恢复（重启后 ${elapsed}s）"
        rm -f "$RESTART_AT"
      else
        log "复核未通过（重启后 ${elapsed}s）：发送仍失败"
      fi
      exit 0
    fi
    # 超过复核期限仍未发出：需要人介入
    log "复核超时：重启后 ${elapsed}s 仍发不出去，可能需要扫码"
    push_once "小D 需要你扫码" "NapCat 重启后 ${elapsed} 秒仍然发不出消息，多半是登录票据失效需要扫码。上服务器看：journalctl -u napcat -n 20"
    rm -f "$RESTART_AT"
    exit 0
  fi

  # ---------- 阶段一：检测 ----------
  if ! systemctl is-active --quiet napcat; then
    log "napcat 没在运行，交给 systemd；本轮不动"
    push_once "NapCat 没在运行" "napcat 服务当前不是 active，systemd 会负责拉起；若持续如此请上服务器看。"
    exit 0
  fi

  local count
  count=$(recent "$WINDOW_MIN" | grep -ac 'EventChecker Failed' || true)
  [ -n "${count:-}" ] || count=0
  if [ "$count" -lt "$THRESHOLD" ]; then
    exit 0   # 安静：绝大多数轮次走这里，不写日志免得把日志刷满
  fi

  # 冷却
  local last=0
  [ -f "$LAST_ALERT.restart" ] && last=$(cat "$LAST_ALERT.restart" 2>/dev/null || echo 0)
  [ -n "${last:-}" ] || last=0
  if [ $(( $(now) - last )) -lt "$COOLDOWN" ]; then
    log "检测到 $count 次 EventChecker，但距上次重启$(( (($(now)-last))/60 ))分钟，仍在冷却期，跳过"
    exit 0
  fi

  # 登录流程保护：这是我 22:53 踩过的坑
  if login_in_flight; then
    log "检测到 $count 次 EventChecker，但登录流程正在进行中（等扫码或快速登录中），不重启"
    exit 0
  fi

  log "判定内核僵死：${WINDOW_MIN} 分钟内 ${count} 次 EventChecker Failed，重启 napcat"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY_RUN=1：到此为止，真的不重启"
    exit 0
  fi
  if systemctl restart napcat; then
    now >"$RESTART_AT"
    now >"$LAST_ALERT.restart"
    log "napcat 已重启（$(systemctl is-active napcat)），下一轮复核发送链路"
  else
    log "!! systemctl restart napcat 失败"
    push_once "重启 NapCat 失败" "systemctl restart napcat 返回非零，请上服务器手动处理。"
  fi
}

main "$@"
