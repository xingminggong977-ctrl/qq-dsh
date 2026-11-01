#!/bin/bash
# 把新的 node-plugin 铺上云、补 token、换 profile 配置、跑测试、重启、验证。
# 需要先把两样东西 scp 到 /tmp：node-plugin.tar.gz（可选还要 qq-profile.cordis.patch.yml）
set -euo pipefail

cd /opt/dsh-qq-agent

echo "=== 1. 旧版本留底 ==="
# live 在才动 .old：live 不在时把 .old 留着，它是唯一的回退。
if [ -d node-plugin ]; then
  rm -rf node-plugin.old
  mv node-plugin node-plugin.old
fi

echo "=== 2. 解包（包的顶层前缀可能是 node-plugin/ 也可能是 qq-dsh/node-plugin/）==="
# 打包机从 qq-dsh/ 里 tar 时没有前缀，从仓库根 tar 时会带上 qq-dsh/。
# 两种都得能落地：解到暂存目录，找到那个含 index.js 的 node-plugin 目录再搬过去。
rm -rf /tmp/plugin-unpack && mkdir -p /tmp/plugin-unpack
tar -xzf /tmp/node-plugin.tar.gz -C /tmp/plugin-unpack
SRC=$(find /tmp/plugin-unpack -type f -path '*/node-plugin/index.js' -printf '%h\n' | head -n 1)
if [ -z "$SRC" ]; then
  echo "解包里找不到 node-plugin/index.js，放弃（旧版本在 node-plugin.old）"
  exit 1
fi
echo "解包来源：$SRC"
mv "$SRC" /opt/dsh-qq-agent/node-plugin
rm -rf /tmp/plugin-unpack
find /opt/dsh-qq-agent/node-plugin -type d -exec chmod 755 {} \;
find /opt/dsh-qq-agent/node-plugin -type f -exec chmod 644 {} \;
chown -R root:root /opt/dsh-qq-agent/node-plugin
ls -1 /opt/dsh-qq-agent/node-plugin/lib/

echo "=== 3. profile 配置（可选）==="
if [ -f /tmp/qq-profile.cordis.patch.yml ]; then
  install -m 0644 /tmp/qq-profile.cordis.patch.yml /root/.dsh/profiles/qq/cordis.patch.yml
  echo "已替换 /root/.dsh/profiles/qq/cordis.patch.yml"
else
  echo "未提供，保持不变"
fi

echo "=== 4. 给 agent 补 NAPCAT_ACCESS_TOKEN ==="
if ! grep -q '^NAPCAT_ACCESS_TOKEN=' /etc/dsh-qq-agent/env; then
  TOKEN=$(grep '^NAPCAT_ACCESS_TOKEN=' /etc/dsh-qq-bridge/env | cut -d= -f2-)
  printf 'NAPCAT_ACCESS_TOKEN=%s\n' "${TOKEN}" >> /etc/dsh-qq-agent/env
  echo "已追加"
else
  echo "已存在，跳过"
fi
chmod 600 /etc/dsh-qq-agent/env
cut -d= -f1 /etc/dsh-qq-agent/env

echo "=== 5. 全量测试 ==="
cd /opt/dsh-qq-agent/node-plugin
node --import ./test/dsh-resolve.js --test test/index.js 2>&1 \
  | grep -E '^ℹ (tests|pass|fail)' || true

echo "=== 6. 重启（有回合在跑就等它跑完，最多 120 秒）==="
# 她正在跟主人说话时重启会把那一轮掐掉，回他一嘴「我这边卡了一下」。等空闲再动。
for _ in $(seq 1 24); do
  BUSY=$(node /tmp/count-busy.mjs | head -n 1)
  if [ "$BUSY" = "0" ]; then break; fi
  echo "还有 $BUSY 个回合没结算，等 5 秒"
  sleep 5
done
echo "重启前未结算回合：$(node /tmp/count-busy.mjs | head -n 1)"
systemctl restart dsh-qq-agent
sleep 8
systemctl is-active dsh-qq-agent

echo "=== 7. 日志 ==="
journalctl -u dsh-qq-agent -n 20 --no-pager -o cat | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g'

echo "=== 8. 审计目录 ==="
ls -la /opt/dsh-qq-agent/audit 2>/dev/null || echo "(还没有 audit 目录：她尚未对外说过话)"
