#!/usr/bin/env bash
# 迁移后全量核对：按 docs/migration-runbook.md §2 的清单逐项确认新机上「一个都没漏」，
# 再对 §5 暗伤、§9 二十四小时观察项打分。只读，不改任何东西。
#
# 用法：sudo bash post-migration-audit.sh
# 退出码：0 全部通过 / 1 有 FAIL
set -u

PASS_N=0
WARN_N=0
FAIL_N=0

ok()   { PASS_N=$((PASS_N + 1)); printf '  [PASS] %-46s %s\n' "$1" "${2-}"; }
warn() { WARN_N=$((WARN_N + 1)); printf '  [WARN] %-46s %s\n' "$1" "${2-}"; }
bad()  { FAIL_N=$((FAIL_N + 1)); printf '  [FAIL] %-46s %s\n' "$1" "${2-}"; }
hdr()  { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
hdr "1. 五个业务服务（漏一个只会静默失效）"
for s in napcat dsh-qq-bridge dsh-qq-agent dsh-qq-crisis dsh-qq-friend; do
  a="$(systemctl is-active "$s" 2>/dev/null || true)"
  e="$(systemctl is-enabled "$s" 2>/dev/null || true)"
  if [ "$a" = active ] && [ "$e" = enabled ]; then ok "服务 $s" "active + enabled"
  else bad "服务 $s" "active=$a enabled=$e"; fi
done

hdr "2. 全部 unit 文件"
UNITS="napcat.service dsh-qq-bridge.service dsh-qq-agent.service \
dsh-qq-crisis.service dsh-qq-friend.service \
dsh-qq-healthcheck.service dsh-qq-healthcheck.timer \
dsh-qq-nightly-digest.service dsh-qq-nightly-digest.timer \
dsh-qq-nightly-report.service dsh-qq-nightly-report.timer \
dsh-qq-nightly-weekly.service dsh-qq-nightly-weekly.timer \
dsh-qq-napcat-watch.service dsh-qq-napcat-watch.timer"
missing=""
for u in $UNITS; do
  p="$(systemctl show -p FragmentPath --value "$u" 2>/dev/null || true)"
  if [ -z "$p" ] || [ "$p" = /dev/null ] || [ ! -f "$p" ]; then missing="$missing $u"; fi
done
if [ -z "$missing" ]; then ok "unit 文件齐全" "15 个"
else bad "缺 unit" "$missing"; fi

hdr "3. 三个 cron"
for f in /etc/cron.d/dsh-qq-backup /etc/cron.d/dsh-qq-diary-merge /etc/cron.d/dsh-qq-github-backup; do
  if [ -f "$f" ]; then ok "cron $(basename "$f")" "$(grep -vc '^[[:space:]]*\(#\|$\)' "$f") 行有效"
  else bad "cron $(basename "$f")" "文件不存在"; fi
done
cs="$(systemctl is-active cron 2>/dev/null || echo unknown)"
[ "$cs" = active ] && ok "cron 守护进程" active || bad "cron 守护进程" "$cs"

hdr "4. 只存在于 /usr/local/bin 的脚本"
for f in dsh-qq-alert.mjs dsh-qq-backup.sh dsh-qq-healthcheck.sh diary-automerge.sh backup-to-github.sh dsh-qq-napcat-watch.sh push-notify.sh; do
  p="/usr/local/bin/$f"
  if [ -x "$p" ]; then ok "脚本 $f" "$(stat -c '%a %U:%G %sB' "$p")"
  else bad "脚本 $f" "缺失或不可执行"; fi
done
bak_n="$(find /usr/local/bin -maxdepth 1 -name '*.bak*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$bak_n" = 0 ] && ok "无 .bak 残留" "0" || warn ".bak 残留" "$bak_n 个"

hdr "5. 配置（只看键在不在，不打印值）"
chk_env() {
  local f="$1"; shift
  if [ ! -f "$f" ]; then bad "配置 $f" "不存在"; return; fi
  local perm miss=""
  perm="$(stat -c '%a' "$f")"
  for k in "$@"; do
    grep -qE "^${k}=.+" "$f" || miss="$miss $k"
  done
  if [ -n "$miss" ]; then bad "配置 $f" "缺键:$miss"
  elif [ "$perm" != 600 ]; then warn "配置 $f" "权限 $perm（应为 600）"
  else ok "配置 $f" "600，键齐全"; fi
}
chk_env /etc/dsh-qq-bridge/env NODE_TOKEN NAPCAT_ACCESS_TOKEN
chk_env /etc/dsh-qq-agent/env NAPCAT_ACCESS_TOKEN
chk_env /etc/dsh-qq-nightly/env NODE_TOKEN OWNER_QQ

asr_key="$(grep -c '^ASR_DASHSCOPE_KEY=.\+' /etc/dsh-qq-bridge/env 2>/dev/null || true)"
[ "${asr_key:-0}" -ge 1 ] && ok "百炼 key" "已写入" || warn "百炼 key" "未写入（语音会退回本地 whisper）"

hdr "6. 数据目录"
p="$(stat -c '%a %U:%G' /var/lib/dsh-qq-bridge 2>/dev/null || echo none)"
if [ "$p" = "700 dshqq:dshqq" ]; then ok "/var/lib/dsh-qq-bridge" "700 dshqq:dshqq"
else warn "/var/lib/dsh-qq-bridge" "$p"; fi
[ -f /var/lib/dsh-qq-bridge/queue.db ] && ok "queue.db" "$(du -h /var/lib/dsh-qq-bridge/queue.db | cut -f1)" || bad "queue.db" "不存在"

for d in /var/lib/dsh-qq-agent /opt/dsh-qq-agent/audit /opt/dsh-qq-agent/persona /opt/dsh-qq-agent/proposals /opt/dsh-qq-agent/nightly /opt/dsh-qq-agent/node-plugin; do
  [ -d "$d" ] && ok "目录 $d" "$(du -sh "$d" 2>/dev/null | cut -f1)" || bad "目录 $d" "不存在"
done

hdr "7. 模型凭据（缺了它她一个字都回不出来）"
CRED=/root/.dsh/.credentials.yaml
if [ -f "$CRED" ]; then
  grep -q 'DEEPSEEK_API_KEY' "$CRED" && ok "$CRED" "600 $(stat -c '%a' "$CRED")" || bad "$CRED" "没有 DEEPSEEK_API_KEY"
else bad "$CRED" "不存在"; fi
[ -f /root/.dsh/llm-deepseek/files-v3.json ] && ok "/root/.dsh/llm-deepseek" "$(du -sh /root/.dsh/llm-deepseek | cut -f1)" || warn "/root/.dsh/llm-deepseek" "不存在"

hdr "8. 暗伤逐条复核（runbook §5）"
sw="$(free -m | awk '/Swap:/{print $2}')"
if [ "${sw:-0}" -gt 0 ]; then ok "暗伤2 swap 已建" "${sw}MB"; else bad "暗伤2 swap" "仍为 0"; fi
swp="$(cat /proc/sys/vm/swappiness)"
[ "$swp" -le 10 ] && ok "暗伤13 swappiness" "$swp" || warn "暗伤13 swappiness" "$swp（应为 ≤10）"
command -v sqlite3 >/dev/null 2>&1 && ok "暗伤3 sqlite3" "$(sqlite3 --version | cut -d' ' -f1)" || warn "暗伤3 sqlite3" "无 CLI（脚本已用 python3 兜底）"

if grep -rqE '^SystemMaxUse=' /etc/systemd/journald.conf.d/ 2>/dev/null; then
  ok "暗伤4 journald 上限" "$(grep -rhE '^SystemMaxUse=' /etc/systemd/journald.conf.d/ | tail -1)"
else bad "暗伤4 journald 上限" "drop-in 里没有 SystemMaxUse"; fi

if [ -f /etc/logrotate.d/dsh-qq ]; then
  if logrotate -d /etc/logrotate.d/dsh-qq >/dev/null 2>&1; then ok "暗伤5 logrotate 配置" "logrotate -d 退出 0"
  else bad "暗伤5 logrotate 配置" "logrotate -d 报错 -> logrotate -d /etc/logrotate.d/dsh-qq"; fi
  grep -qE '^[[:space:]]*su root syslog' /etc/logrotate.d/dsh-qq && ok "暗伤5 su 指令" "存在" || warn "暗伤5 su 指令" "缺失（parent dir 权限会拒绝轮转）"
else bad "暗伤5 logrotate 配置" "文件不存在"; fi

if grep -q -- '-q 10002' /opt/napcat/launcher.sh 2>/dev/null; then
  ok "暗伤1 快速登录" "launcher.sh 带 -q"
else bad "暗伤1 快速登录" "launcher.sh 没有 -q"; fi

hc=/usr/local/bin/dsh-qq-healthcheck.sh
if [ -f "$hc" ]; then
  n=0
  for s in napcat dsh-qq-bridge dsh-qq-agent dsh-qq-crisis dsh-qq-friend; do grep -q "$s" "$hc" && n=$((n + 1)); done
  [ "$n" -eq 5 ] && ok "暗伤7 巡检覆盖" "5 个服务" || bad "暗伤7 巡检覆盖" "只覆盖 $n/5"
else bad "暗伤7 巡检脚本" "不存在"; fi

a="$(journalctl -u dsh-qq-bridge -n 500 --no-pager 2>/dev/null | grep -o '"asr":"[^"]*"' | tail -1)"
case "$a" in
  *dashscope*) ok "暗伤11 转写路线" "$a" ;;
  *none*)      warn "暗伤11 转写路线" "$a（尚未用上百炼）" ;;
  *)           warn "暗伤11 转写路线" "${a:-未找到启动行}" ;;
esac

hdr "9. 二十四小时观察项（runbook §9）"
restarts="$(systemctl show -p NRestarts --value dsh-qq-bridge 2>/dev/null || echo '?')"
[ "${restarts:-1}" = 0 ] && ok "bridge NRestarts" "0" || warn "bridge NRestarts" "$restarts"

vf="$(journalctl -u dsh-qq-bridge --since '24 hours ago' --no-pager 2>/dev/null | grep -c 'voice transcription failed' || true)"
[ "${vf:-0}" -eq 0 ] && ok "24h 内转写失败" "0" || warn "24h 内转写失败" "$vf 次"

AUD="$(ls -t /opt/dsh-qq-agent/audit/audit-*.jsonl 2>/dev/null | head -1)"
if [ -n "$AUD" ]; then
  tot="$(wc -l <"$AUD" | tr -d ' ')"
  badn="$(grep -c '"ok":false' "$AUD" || true)"
  if [ "${tot:-0}" -gt 0 ]; then
    pct=$((badn * 100 / tot))
    [ "$pct" -lt 5 ] && ok "审计 ok:false 占比" "$badn/$tot = ${pct}%" || warn "审计 ok:false 占比" "$badn/$tot = ${pct}%"
  else warn "审计文件为空" "$AUD"; fi
else bad "审计文件" "audit-*.jsonl 不存在"; fi

dfp="$(df -P / | awk 'NR==2{print $5}' | tr -d '%')"
[ "${dfp:-100}" -lt 60 ] && ok "根分区使用率" "${dfp}%" || warn "根分区使用率" "${dfp}%"

hdr "10. 外部集成与投递"
for lg in /var/log/dsh-qq-backup.log /var/log/dsh-qq-github.log /var/log/dsh-qq-diary-merge.log /var/log/dsh-qq-healthcheck.log; do
  if [ -f "$lg" ]; then ok "$(basename "$lg")" "最后写入 $(stat -c '%y' "$lg" | cut -d. -f1)"
  else warn "$(basename "$lg")" "不存在（对应 cron 可能还没跑过）"; fi
done

TOKEN="$(grep -m1 '^NODE_TOKEN=' /etc/dsh-qq-bridge/env 2>/dev/null | cut -d= -f2-)"
if [ -n "${TOKEN:-}" ]; then
  st="$(curl -s -m 5 -H "Authorization: Bearer $TOKEN" \
        http://127.0.0.1:8787/node/pc/status 2>/dev/null || true)"
  case "$st" in
    *online*)     ok "PC 通道" "$(printf '%s' "$st" | cut -c1-90)" ;;
    *just_lost*)  warn "PC 通道" "刚从线掉下来" ;;
    *offline*)    warn "PC 通道" "离线（本机 pc-agent 没连）" ;;
    *)            warn "PC 通道" "${st:-无响应}" ;;
  esac
else warn "PC 通道" "读不到 NODE_TOKEN"; fi

printf '\n--- 汇总 ---\n  %s pass / %s warn / %s fail\n' "$PASS_N" "$WARN_N" "$FAIL_N"
if [ "$FAIL_N" -eq 0 ]; then echo "  没有硬伤。"; exit 0; fi
echo "  有 $FAIL_N 项必须处理。"; exit 1
