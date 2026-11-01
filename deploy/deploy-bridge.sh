#!/bin/bash
# 把新的 bridge 铺上云、补齐 ASR 环境变量、跑测试、重启、验证。
# 需要先 scp /tmp/bridge.tar.gz（可选 /tmp/bridge.env.asr 里放要追加的变量）
set -euo pipefail

ENVFILE=/etc/dsh-qq-bridge/env
DIR=/opt/dsh-qq-bridge

echo "=== 1. 旧版本留底 ==="
rm -rf "$DIR.old"
cp -a "$DIR" "$DIR.old"

echo "=== 2. 解包 ==="
# The tarball has a top-level `bridge/`, but the live tree is `dsh-qq-bridge/`,
# so unpack to a scratch dir and copy the contents across by name-agnostic path.
rm -rf /tmp/bridge-unpack
mkdir -p /tmp/bridge-unpack
tar -xzf /tmp/bridge.tar.gz -C /tmp/bridge-unpack
SRC=$(find /tmp/bridge-unpack -mindepth 1 -maxdepth 1 -type d | head -1)
test -n "$SRC" || { echo "tarball has no top-level directory"; exit 1; }
rm -rf "$DIR"
mkdir -p "$DIR"
cp -a "$SRC"/. "$DIR"/
rm -rf /tmp/bridge-unpack /opt/bridge
find "$DIR" -type d -exec chmod 755 {} \;
find "$DIR" -type f -exec chmod 644 {} \;
chmod 755 "$DIR/scripts/transcribe.py" 2>/dev/null || true
chown -R root:root "$DIR"
ls -1 "$DIR"

echo "=== 3. ASR 环境变量 ==="
add_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENVFILE"; then
    echo "  $key 已存在，跳过"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENVFILE"
    echo "  $key 已追加"
  fi
}
add_env ASR_PYTHON /opt/asr-venv/bin/python
add_env ASR_SCRIPT "$DIR/scripts/transcribe.py"
add_env ASR_MODEL_DIR /opt/asr-models
# 云端转写：URL/模型名先写上，KEY 留空——本脚本不碰凭据，也绝不给凭据写默认值。
# 三个都给才启用；KEY 空着就是"还没开"，行为退回本地 whisper。
add_env ASR_URL ''
add_env ASR_MODEL ''
add_env ASR_LANGUAGE zh
add_env ASR_REMOTE_TIMEOUT_MS 15000
add_env ASR_API_KEY ''
# 百炼 paraformer：异步链路，key 与上面那条不通用；KEY 留空即未启用。
add_env ASR_DASHSCOPE_MODEL paraformer-v2
add_env ASR_DASHSCOPE_REGION beijing
add_env ASR_DASHSCOPE_TIMEOUT_MS 20000
add_env ASR_DASHSCOPE_KEY ''

# 语音回复：dashscope/CosyVoice 这条路线的风格指令（只有 v3/v3.5 认它）。空＝不加指令。
add_env TTS_INSTRUCTION ''

# 主动开口：线上一直跑代码默认（间隔中位 25 分钟、一天问 30 次）。这里显式定下来，
# 免得以后改默认值又悄悄改变体感。90 分钟是「不打扰」与「还惦记着你」的折中。
add_env PROACTIVE_ENABLED on
add_env PROACTIVE_MIN_GAP_MS 5400000
add_env PROACTIVE_MAX_ASKS_PER_DAY 8
add_env PROACTIVE_MAX_PER_DAY 30
add_env PROACTIVE_REQUIRE_ACTIVITY on
chmod 600 "$ENVFILE"

echo "=== 4. 转写引擎自检（直接喂一段静音）==="
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -y /tmp/probe-silence.mp3
/opt/asr-venv/bin/python "$DIR/scripts/transcribe.py" /tmp/probe-silence.mp3 /opt/asr-models | head -1
rm -f /tmp/probe-silence.mp3

echo "=== 5. 全量测试 ==="
cd "$DIR"
node --test test/*.test.js 2>&1 | grep -E '^ℹ (tests|pass|fail)' || true

echo "=== 5b. /node/send 路由冒烟（只走拒绝路径，不真发消息）==="
TOKEN=$(grep -E '^NODE_TOKEN=' "$ENVFILE" | cut -d= -f2- || true)
echo -n "  无 token 应 401: "
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"to":"10001","text":"probe"}' http://127.0.0.1:8787/node/send || true
echo -n "  非主人应 403: "
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"kind":"private","to":"1000000","text":"probe"}' http://127.0.0.1:8787/node/send || true
echo

echo "=== 6. 重启 ==="
systemctl restart dsh-qq-bridge
sleep 4
systemctl is-active dsh-qq-bridge

echo "=== 7. 日志 ==="
journalctl -u dsh-qq-bridge -n 12 --no-pager -o cat | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g'
echo "--- 主动开口闸门相关 ---"
journalctl -u dsh-qq-bridge --since=-3min --no-pager -o cat | grep -a -e proactive -e 主动 || echo "  （3 分钟内还没有闸门日志，第一 tick 可能恰好是可问状态）"
