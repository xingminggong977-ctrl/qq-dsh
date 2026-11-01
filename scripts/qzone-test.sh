#!/bin/bash
# 试 send_qzone_msg：参数里 ugc_right=64 表示仅自己可见，先别污染他的空间。
set -uo pipefail

cd "$(dirname "$0")" || exit 1

TOKEN=$(grep '^NAPCAT_ACCESS_TOKEN=' /etc/dsh-qq-bridge/env | cut -d= -f2-)
if [ -z "${TOKEN}" ]; then
  echo "没取到 NAPCAT_ACCESS_TOKEN"
  exit 1
fi

echo "--- token 长度: ${#TOKEN} ---"
echo "--- 调用 send_qzone_msg（ugc_right=64 仅自己可见） ---"
NAPCAT_TOKEN="${TOKEN}" NAPCAT_URL=ws://127.0.0.1:3001 \
  node napcat-call.mjs send_qzone_msg qzone-test-params.json
echo "--- 退出码: $? ---"
