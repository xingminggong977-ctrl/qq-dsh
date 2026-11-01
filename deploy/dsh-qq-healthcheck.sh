#!/bin/bash
# 小D 的健康巡检：三个服务 + 两个端口 + bridge /health + QQ 进程。
# 只在「状态发生变化」时告警，避免每 10 分钟骚扰一次。
# 告警走两条腿：QQ 私聊（快，但 QQ 掉线时也哑）与微信推送（慢一点，但不依赖 QQ）。
set -uo pipefail

STATE=/var/lib/dsh-qq-agent/health.state
LOG=/var/log/dsh-qq-healthcheck.log
ALERT=/usr/local/bin/dsh-qq-alert.mjs
PUSH=/usr/local/bin/push-notify.sh
ENVFILE=/etc/dsh-qq-agent/env

problems=()

for svc in napcat dsh-qq-bridge dsh-qq-agent; do
  systemctl is-active --quiet "$svc" || problems+=("$svc 没在运行")
done

ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:3001' || problems+=("NapCat 的 3001 没在听")
ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:8787' || problems+=("bridge 的 8787 没在听")

health=$(curl -s --max-time 5 http://127.0.0.1:8787/health 2>/dev/null || true)
case "$health" in
  *'"ok":true'*) ;;
  *) problems+=("bridge /health 异常: ${health:0:120}") ;;
esac
# `ok:true` 只说桥自己活着。NapCat 停在登录页时进程还在、端口还在，
# 但桥连不上，她其实聋了——17:35 那次就是这么哑了两个小时没人知道。
case "$health" in
  *'"napcat":"down"'*) problems+=("QQ 掉线了：桥连不上 NapCat，她收不到任何消息") ;;
esac

pgrep -f '/opt/QQ/qq --no-sandbox' >/dev/null 2>&1 || problems+=("QQ 进程不在")

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

if [ "${#problems[@]}" -eq 0 ]; then now_state=ok; else now_state=bad; fi
prev_state=$(cat "$STATE" 2>/dev/null || echo unknown)

if [ "$now_state" != "$prev_state" ]; then
  if [ "$now_state" = bad ]; then
    joined=$(IFS='；'; echo "${problems[*]}")
    message="【小D 掉线告警】${joined}"
  else
    message="【小D 恢复了】刚才的问题都没了，可以正常说话。"
  fi
  printf '%s' "$now_state" > "$STATE"
  token=$(grep '^NAPCAT_ACCESS_TOKEN=' "$ENVFILE" 2>/dev/null | cut -d= -f2-)
  NAPCAT_TOKEN="$token" node "$ALERT" "$message" >> "$LOG" 2>&1 || echo "$(date -Is) QQ 告警发送失败" >> "$LOG"
  # QQ 掉线时 NapCat 也断了，这条出口必须独立于 QQ，否则最需要报警的一刻正好静音。
  push_title="小D 掉线了"
  [ "$now_state" = ok ] && push_title="小D 恢复了"
  "$PUSH" "$push_title" "$(printf '%s\n\n%s' "$message" "$(date -Is)")" >> "$LOG" 2>&1 || echo "$(date -Is) 微信推送失败" >> "$LOG"
fi

joined=$(IFS='；'; echo "${problems[*]:-}")
echo "$(date -Is) $now_state ${joined}" >> "$LOG"

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
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
  tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
