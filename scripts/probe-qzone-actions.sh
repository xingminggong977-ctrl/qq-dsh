#!/bin/bash
F=/opt/napcat/napcat/plugins/napcat-plugin-ssqq/webui/dist/assets/js/main-BlF3SHJx.js

echo "=== 含 qzone 的标识符（去重） ==="
grep -rhoiE '[a-z_]*qzone[a-z_]*' "$F" | sort -u

echo
echo "=== 疑似动作名（xxx_qzone 形式） ==="
grep -rhoE '[a-z_]+_qzone[a-z_]*' "$F" | sort -u

echo
echo "=== send_qzone_msg 附近 160 字符 ==="
grep -rhoE '.{0,80}send_qzone_msg.{0,160}' "$F" | head -2
