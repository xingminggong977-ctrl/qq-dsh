#!/usr/bin/env bash
# 把语音合成切到百炼 CosyVoice 的复刻音色（幂等：已有的键覆盖，没有的追加）。
# 只改 /etc/dsh-qq-bridge/env，不碰凭据本身——key 用的是 TTS_DASHSCOPE_KEY 或回退 ASR_DASHSCOPE_KEY。
set -euo pipefail

ENVFILE=/etc/dsh-qq-bridge/env
VOICE="${1:-}"   # 复刻返回的 voice id
if [[ -z "$VOICE" ]]; then
  echo "用法: set-cosyvoice-env.sh <voiceId> [script]" >&2
  exit 2
fi
SCRIPT="${2:-/opt/dsh-qq-bridge/scripts/say-cosyvoice.py}"

[[ -f "$ENVFILE" ]] || { echo "找不到 $ENVFILE" >&2; exit 2; }
[[ -f "$SCRIPT" ]] || { echo "找不到合成脚本 $SCRIPT" >&2; exit 2; }

cp -a "$ENVFILE" "$ENVFILE.bak-$(date +%Y%m%d-%H%M%S)"

set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENVFILE"; then
    # 用 | 作分隔符，值里带 / 也不用转义
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENVFILE"
    echo "  $key = $value（覆盖）"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENVFILE"
    echo "  $key = $value（新增）"
  fi
}

set_env TTS_ENABLED on
set_env TTS_PROVIDER dashscope
set_env TTS_MODEL cosyvoice-v2
set_env TTS_VOICE "$VOICE"
set_env TTS_SCRIPT "$SCRIPT"
set_env TTS_PYTHON /opt/asr-venv/bin/python
set_env TTS_SPEECH_RATE 1.0
set_env TTS_PITCH_RATE 1.0
set_env TTS_MAX_CHARS 60
set_env TTS_DAILY_MAX 10

chown root:root "$ENVFILE"
chmod 600 "$ENVFILE"
echo "--- 生效后的 TTS 键 ---"
grep -aE '^TTS_' "$ENVFILE" | sed -e 's|^TTS_DASHSCOPE_KEY=.*|TTS_DASHSCOPE_KEY=(未设置)|'

systemctl restart dsh-qq-bridge
sleep 2
systemctl is-active dsh-qq-bridge
echo "--- 启动日志 ---"
journalctl -u dsh-qq-bridge -n 8 --no-pager | grep -aE 'listening|armed|websocket' | tail -4
