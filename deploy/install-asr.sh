#!/bin/bash
# 在服务器上装一个自包含的语音转写引擎（faster-whisper，CPU int8），
# 并把 small 模型预下到固定目录，避免第一次真用时现下。
set -uo pipefail

VENV=/opt/asr-venv
MODELS=/opt/asr-models
PIP_MIRROR=https://mirrors.aliyun.com/pypi/simple/
export HF_ENDPOINT=https://hf-mirror.com

echo "[1/4] venv"
python3 -m venv "$VENV" || { apt-get update -qq && apt-get install -y -qq python3-venv; python3 -m venv "$VENV"; }

echo "[2/4] pip install faster-whisper"
"$VENV"/bin/pip install --quiet --upgrade pip -i "$PIP_MIRROR"
"$VENV"/bin/pip install --quiet -i "$PIP_MIRROR" faster-whisper 2>&1 | tail -5 || {
  echo "阿里云源失败，回退官方 PyPI"
  "$VENV"/bin/pip install --quiet faster-whisper 2>&1 | tail -5
}

echo "[3/4] 预下 small 模型到 $MODELS"
mkdir -p "$MODELS"
"$VENV"/bin/python - <<'PY'
import os
from faster_whisper import WhisperModel
print('HF_ENDPOINT =', os.environ.get('HF_ENDPOINT'))
m = WhisperModel('small', device='cpu', compute_type='int8', download_root='/opt/asr-models')
print('model ready')
PY

echo "[4/4] 自检（合成 1 秒静音，只验证模型能加载并出结果）"
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -y /tmp/silence.wav
"$VENV"/bin/python - <<'PY'
from faster_whisper import WhisperModel
m = WhisperModel('small', device='cpu', compute_type='int8', download_root='/opt/asr-models')
segments, info = m.transcribe('/tmp/silence.wav', language='zh', vad_filter=True)
text = ''.join(s.text for s in segments).strip()
print('OK lang=%s dur=%.2fs text=%r' % (info.language, info.duration, text))
PY
rm -f /tmp/silence.wav
echo "=== 完成 ==="
du -sh "$MODELS" "$VENV" 2>/dev/null
