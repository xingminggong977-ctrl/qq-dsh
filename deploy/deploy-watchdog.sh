#!/usr/bin/env bash
# 部署并验证内核看门狗：语法 → 安装 → 用真实日志验判定 → 装 timer。
set -uo pipefail
S=/usr/local/bin/dsh-qq-napcat-watch.sh
SRC=/tmp/hostbin/napcat-watch.sh

echo "=== 1. 语法检查 ==="
bash -n "$SRC" && echo "bash -n 通过"

echo
echo "=== 2. 安装（走仓库的安装器，保留备份惯例）==="
install -m 0755 -o root -g root "$SRC" "$S" && echo "已安装 $S"

echo
echo "=== 3. 用真实日志验判定逻辑（DRY_RUN，绝不重启）==="
echo "--- 3a. 默认窗口(10min)：现在应该安静 ---"
bash "$S"; echo "退出码=$? ；新增日志："
tail -2 /var/log/dsh-qq-napcat-watch.log 2>/dev/null || echo "(无日志=安静，符合预期)"

echo "--- 3b. 放宽到 14 小时、阈值 1：应该判定僵死但被 DRY_RUN 拦下 ---"
WINDOW_MIN=840 THRESHOLD=1 DRY_RUN=1 bash "$S"; echo "退出码=$?"
tail -3 /var/log/dsh-qq-napcat-watch.log 2>/dev/null

echo
echo "=== 4. 登录流程保护是否生效（当前不在登录中，应返回'不重启'或安静）==="
journalctl -u napcat --since '-8min' --no-pager -o cat 2>/dev/null | sed -r 's/\x1b\[[0-9;]*m//g' \
  | grep -acE '二维码已被扫描|正在快速登录|请扫描下面的二维码' | sed 's/^/近8分钟命中登录流程关键字次数: /'

echo
echo "=== 5. 微信推送通道是否就位 ==="
[ -x /usr/local/bin/push-notify.sh ] && echo "push-notify.sh 可执行" || echo "!! push-notify.sh 缺失"

echo
echo "=== 6. 装 timer ==="
install -m 0644 /tmp/units/dsh-qq-napcat-watch.service /etc/systemd/system/dsh-qq-napcat-watch.service
install -m 0644 /tmp/units/dsh-qq-napcat-watch.timer /etc/systemd/system/dsh-qq-napcat-watch.timer
systemctl daemon-reload
systemctl enable --now dsh-qq-napcat-watch.timer 2>&1 | tail -2
echo "--- timer 状态 ---"
systemctl list-timers dsh-qq-napcat-watch.timer --no-pager 2>&1 | head -3
