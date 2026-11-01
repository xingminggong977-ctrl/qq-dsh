#!/bin/bash
# 小D 的健康巡检：五个服务 + 两个端口 + bridge /health + QQ 进程 + 备份 + 磁盘。
#
# 2026-10-26 修：原先只巡 napcat / dsh-qq-bridge / dsh-qq-agent 三个，
# 漏了 dsh-qq-crisis（危机词监控）和 dsh-qq-friend（自动加好友）。
# 这两个服务挂了没有任何外部症状——QQ 照常收发，只是危机词不再触发、
# 好友申请不再自动通过——所以必须由巡检兜住。
#
# 三条防误报的规矩（2026-10-25 加）：
#   1. 服务刚启动或刚退出 120 秒内，不判它掉线——重启不是我死了。
#   2. 坏状态第一次只记 pending，连续两轮都坏才真的告警。
#   3. 只有真报过 bad 之后才发"恢复"，抖动全程静默。
#
# 告警走两条腿：QQ 私聊（快，但 QQ 掉线时也哑）与微信推送（慢一点，但不依赖 QQ）。
set -uo pipefail

STATE=/var/lib/dsh-qq-agent/health.state
STRIKE=/var/lib/dsh-qq-agent/health.strikes
LOG=/var/log/dsh-qq-healthcheck.log
ALERT=/usr/local/bin/dsh-qq-alert.mjs
PUSH=/usr/local/bin/push-notify.sh
ENVFILE=/etc/dsh-qq-agent/env

GRACE=120   # 秒：服务刚启动/刚退出后的宽限
CONFIRM=2   # 连续几轮坏才发告警

problems=()

# 当前开机后的微秒数
mono_us() { awk '{printf "%.0f", $1*1000000}' /proc/uptime; }

# 服务在 GRACE 秒内活跃过（刚起来或刚退出），返回 0
recently_touched() {
  local svc=$1 now_us enter leave
  now_us=$(mono_us)
  enter=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$svc" 2>/dev/null | tr -dc '0-9')
  leave=$(systemctl show -p InactiveEnterTimestampMonotonic --value "$svc" 2>/dev/null | tr -dc '0-9')
  if [ -n "${enter:-}" ] && [ "${enter:-0}" -gt 0 ] && [ $((now_us - enter)) -lt $((GRACE * 1000000)) ]; then
    return 0
  fi
  if [ -n "${leave:-}" ] && [ "${leave:-0}" -gt 0 ] && [ $((now_us - leave)) -lt $((GRACE * 1000000)) ]; then
    return 0
  fi
  return 1
}

napcat_fresh=0
bridge_fresh=0
recently_touched napcat && napcat_fresh=1
recently_touched dsh-qq-bridge && bridge_fresh=1

for svc in napcat dsh-qq-bridge dsh-qq-agent dsh-qq-crisis dsh-qq-friend; do
  systemctl is-active --quiet "$svc" && continue
  recently_touched "$svc" && continue
  problems+=("$svc 没在运行")
done

# NapCat 刚起来时端口和 QQ 进程都还在路上，先别判。
if [ "$napcat_fresh" -eq 0 ]; then
  ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:3001' || problems+=("NapCat 的 3001 没在听")
  pgrep -f '/opt/QQ/qq --no-sandbox' >/dev/null 2>&1 || problems+=("QQ 进程不在")
fi

if [ "$bridge_fresh" -eq 0 ]; then
  ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:8787' || problems+=("bridge 的 8787 没在听")
  health=$(curl -s --max-time 5 http://127.0.0.1:8787/health 2>/dev/null || true)
  case "$health" in
    *'"ok":true'*) ;;
    *) problems+=("bridge /health 异常: ${health:0:120}") ;;
  esac
fi

# 备份：最近一份超过 36 小时没更新，说明备份 cron 悄悄坏了。
newest=$(ls -1t /var/backups/dsh-qq/*.tar.gz 2>/dev/null | head -1)
if [ -z "$newest" ]; then
  problems+=("一份备份都没有")
elif [ -n "$(find "$newest" -mmin +2160 2>/dev/null)" ]; then
  problems+=("最新备份已超过 36 小时未更新: $(basename "$newest")")
fi

# 磁盘：装不下日志和数据库时，她会先坏在写入上。
used=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$used" ] && [ "$used" -ge 85 ]; then
  problems+=("根分区已用 ${used}%")
fi

now_state=ok
[ "${#problems[@]}" -gt 0 ] && now_state=bad
prev_state=$(cat "$STATE" 2>/dev/null || echo unknown)
strikes=$(cat "$STRIKE" 2>/dev/null || echo 0)
[[ "$strikes" =~ ^[0-9]+$ ]] || strikes=0

send_alert() {
  local msg=$1 title
  token=$(grep '^NAPCAT_ACCESS_TOKEN=' "$ENVFILE" 2>/dev/null | cut -d= -f2-)
  NAPCAT_TOKEN="$token" node "$ALERT" "$msg" >>"$LOG" 2>&1 || echo "$(date -Is) QQ 告警发送失败" >>"$LOG"
  if [ "$now_state" = ok ]; then title="小D 恢复了"; else title="小D 掉线了"; fi
  "$PUSH" "$title" "$(printf '%s\n\n%s' "$msg" "$(date -Is)")" >>"$LOG" 2>&1 || echo "$(date -Is) 微信推送失败" >>"$LOG"
}

if [ "$now_state" = ok ]; then
  strikes=0
  if [ "$prev_state" = bad ]; then
    send_alert "【小D 恢复了】刚才的问题都没了，可以正常说话。"
  fi
  printf 'ok' >"$STATE"
else
  strikes=$((strikes + 1))
  if [ "$strikes" -ge "$CONFIRM" ]; then
    if [ "$prev_state" != bad ]; then
      joined=$(IFS='；'; echo "${problems[*]}")
      send_alert "【小D 掉线告警】${joined}"
    fi
    printf 'bad' >"$STATE"
  else
    # 第一次坏先憋一轮，可能是重启抖了一下
    printf 'pending' >"$STATE"
  fi
fi
printf '%s\n' "$strikes" >"$STRIKE"

joined=$(IFS='；'; echo "${problems[*]:-}")
echo "$(date -Is) $now_state strikes=$strikes ${joined}" >>"$LOG"

# GitHub 令牌 90 天过期。从第 80 天起，每天提醒一次（同一天只提醒一次）。
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

# 日志按行数轮转，留最近 2000 行。
if [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
  tail -n 1000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
