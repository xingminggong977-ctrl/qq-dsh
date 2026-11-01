#!/bin/bash
# 微信推送出口：QQ 掉线时 NapCat 也断了，这时的告警不能走 QQ。
# 用法：push-notify.sh "标题" "正文"
# 渠道由 /etc/dsh-qq-agent/push-channel 决定（pushplus | serverchan），
# 令牌在 /etc/dsh-qq-agent/push-token（0600）。缺任意一个就静默跳过。
set -uo pipefail

TITLE=${1:-小D 通知}
BODY=${2:-}
TOKENFILE=/etc/dsh-qq-agent/push-token
CHANNELFILE=/etc/dsh-qq-agent/push-channel

[ -r "$TOKENFILE" ] || exit 0
token=$(tr -d ' \r\n' < "$TOKENFILE")
[ -n "$token" ] || exit 0

channel=$(tr -d ' \r\n' < "$CHANNELFILE" 2>/dev/null || true)
[ -n "$channel" ] || channel=pushplus

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

case "$channel" in
  pushplus)
    payload=$(printf '{"token":"%s","title":"%s","content":"%s","template":"txt"}' \
      "$(json_escape "$token")" "$(json_escape "$TITLE")" "$(json_escape "$BODY")")
    response=$(curl -s --max-time 8 -H 'Content-Type: application/json' \
      -d "$payload" https://www.pushplus.plus/send 2>&1)
    ;;
  serverchan)
    response=$(curl -s --max-time 8 \
      --data-urlencode "title=$TITLE" \
      --data-urlencode "desp=$BODY" \
      "https://sctapi.ftqq.com/${token}.send" 2>&1)
    ;;
  *)
    echo "unknown push channel: $channel"
    exit 1
    ;;
esac

# PushPlus 成功返回 200（不是 0），Server酱 成功返回 0，两家都要认。
# 只把明确的成功码当成功，其余一律打出来，方便事后查。
case "$response" in
  *'"code":0'*|*'"code": 0'*|*'"code":200'*|*'"code": 200'*) exit 0 ;;
  *) echo "push failed: ${response:0:200}"; exit 1 ;;
esac
