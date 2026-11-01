#!/bin/bash
# 把那条私密说说换成公开版：先发一条 ugc_right=1，再把旧的 tid 删掉。
set -uo pipefail

CFG=/opt/napcat/napcat/config/onebot11_10002.json
TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)
if [ -z "${TOKEN}" ]; then
  echo "FAIL: 没取到 token"
  exit 1
fi
echo "--- token 长度: ${#TOKEN} ---"

echo "=== 1) 发公开版 ==="
NAPCAT_TOKEN="${TOKEN}" NAPCAT_URL=ws://127.0.0.1:3001 \
  node /tmp/dsh/napcat-call.mjs send_qzone_msg /tmp/dsh/qzone-publish-params.json
echo "--- send 退出码: $? ---"

echo "=== 2) 删掉旧的私密那条 ==="
NAPCAT_TOKEN="${TOKEN}" NAPCAT_URL=ws://127.0.0.1:3001 \
  node /tmp/dsh/napcat-call.mjs delete_qzone_msg /tmp/dsh/qzone-delete-params.json
echo "--- delete 退出码: $? ---"
