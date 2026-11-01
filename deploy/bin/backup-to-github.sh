#!/bin/bash
# 把她的身家推到私有 GitHub 仓库做异地备份。
#
# 2026-10-27 换机重写：新机 **github.com:443 不通**（TCP 超时），git push 必挂；
# 而 api.github.com / uploads.github.com / codeload 都通。所以传输层从
# `git push` 换成 **Releases 资产上传**：同样的仓库、同样的 PAT，只走能通的域名。
#
# 刻意不打包任何密钥：
#   /etc/dsh-qq-agent/env            含 QQ_NODE_TOKEN / NAPCAT_ACCESS_TOKEN
#   /etc/dsh-qq-bridge/env           含 NODE_TOKEN / 百炼 key
#   /root/.dsh/.credentials.yaml     含 DEEPSEEK_API_KEY
# 这些丢了能重新生成；推到 GitHub（哪怕私有）是永久留痕，风险不对称。
#
# 失败一定吵闹：写日志 + 微信推送 + exit 1。原来 push 失败只体现在日志里，没人会看。
set -uo pipefail

CONF=/etc/dsh-qq-agent
TOKEN_FILE="$CONF/github-token"
REPO_FILE="$CONF/github-repo"
STAGE=$(mktemp -d /tmp/dsh-gh-stage.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

TAG=backup
KEEP=7
API=https://api.github.com
UPLOADS=https://uploads.github.com

fail() {
  echo "备份失败：$*"
  if [ -x /usr/local/bin/push-notify.sh ]; then
    /usr/local/bin/push-notify.sh "小D 异地备份失败" "$*" >/dev/null 2>&1 || true
  fi
  exit 1
}

[ -r "$TOKEN_FILE" ] || fail "缺少 $TOKEN_FILE（写入 PAT）"
[ -r "$REPO_FILE" ] || fail "缺少 $REPO_FILE（写入 owner/repo）"
TOKEN=$(tr -d ' \r\n' <"$TOKEN_FILE")
REPO=$(tr -d ' \r\n' <"$REPO_FILE")
[ -n "$TOKEN" ] && [ -n "$REPO" ] || fail "token 或 repo 为空"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME="dsh-qq-${STAMP}.tar.gz"
MNAME="MANIFEST-${STAMP}.txt"

api() { # api METHOD PATH [DATA]
  local method="$1" path="$2" data="${3-}"
  if [ -n "$data" ]; then
    curl -sS -m 30 -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
      -d "$data" "$API$path"
  else
    curl -sS -m 30 -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H 'Accept: application/vnd.github+json' "$API$path"
  fi
}

echo "=== 1. 打包（不含密钥）==="
MEMBERS=()
for p in opt/dsh-qq-agent var/lib/dsh-qq-agent etc/dsh-qq-agent/env.example \
         root/.dsh/profiles/qq/package.json root/.dsh/profiles/qq/cordis.patch.yml; do
  [ -e "/$p" ] && MEMBERS+=("$p")
done
[ "${#MEMBERS[@]}" -ge 2 ] || fail "可用打包路径不足（${MEMBERS[*]:-无}）"
tar -czf "$STAGE/snapshot.tar.gz" \
  --exclude='*.log' \
  --exclude='*/node_modules/*' \
  --exclude='*/workspace/pylibs' \
  --exclude='*/workspace/backup/*.tar.gz' \
  --exclude='*.pyc' \
  --exclude='__pycache__' \
  -C / "${MEMBERS[@]}"
[ -s "$STAGE/snapshot.tar.gz" ] || fail "打包结果为空"
BYTES=$(stat -c %s "$STAGE/snapshot.tar.gz")
SHA=$(sha256sum "$STAGE/snapshot.tar.gz" | cut -d' ' -f1)
echo "   $BYTES bytes  sha256 ${SHA:0:16}…"

{
  echo "snapshot: $STAMP"
  echo "bytes:    $BYTES"
  echo "sha256:   $SHA"
  echo "host:     $(hostname) $(curl -sS -m 5 https://api.ipify.org 2>/dev/null || echo '?')"
  echo
  echo "excluded on purpose: /etc/dsh-qq-agent/env, /etc/dsh-qq-bridge/env, /root/.dsh/.credentials.yaml"
  echo
  echo "services at snapshot:"
  for s in napcat dsh-qq-bridge dsh-qq-agent dsh-qq-crisis dsh-qq-friend; do
    printf '  %-18s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
  done
  echo
  echo "persona:"
  find /opt/dsh-qq-agent/persona -type f 2>/dev/null | sort | while read -r f; do
    printf '  %-58s %s B\n' "${f#/opt/dsh-qq-agent/}" "$(stat -c %s "$f")"
  done
} >"$STAGE/MANIFEST.txt"

echo "=== 2. 定位 release（tag=$TAG）==="
RID=$(api GET "/repos/$REPO/releases/tags/$TAG" | jq -r '.id // empty')
if [ -z "$RID" ]; then
  echo "   release 不存在，创建"
  RID=$(api POST "/repos/$REPO/releases" \
    "{\"tag_name\":\"$TAG\",\"name\":\"夜间备份\",\"body\":\"由 /usr/local/bin/backup-to-github.sh 自动维护，只保留最近 $KEEP 份。\"}" \
    | jq -r '.id // empty')
  [ -n "$RID" ] || fail "创建 release 失败（检查 PAT 是否有 repo 写权限）"
fi
echo "   release id=$RID"

echo "=== 3. 上传资产 ==="
upload() { # upload FILE ASSET_NAME CONTENT_TYPE
  local file="$1" name="$2" ctype="$3"
  # 同名先删，否则 409
  local old
  old=$(api GET "/repos/$REPO/releases/$RID/assets?per_page=100" \
        | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -1)
  if [ -n "$old" ]; then api DELETE "/repos/$REPO/releases/assets/$old" >/dev/null; fi
  local resp
  resp=$(curl -sS -m 300 -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H "Content-Type: $ctype" \
    --data-binary "@$file" \
    "$UPLOADS/repos/$REPO/releases/$RID/assets?name=$name")
  local size state
  size=$(printf '%s' "$resp" | jq -r '.size // 0')
  state=$(printf '%s' "$resp" | jq -r '.state // "none"')
  local want
  want=$(stat -c %s "$file")
  if [ "$size" != "$want" ] || [ "$state" != uploaded ]; then
    fail "上传 $name 后校验不一致（远端 size=$size state=$state，本地 $want）"
  fi
  echo "   $name  $size bytes  $state"
}

upload "$STAGE/snapshot.tar.gz" "$NAME" application/gzip
upload "$STAGE/MANIFEST.txt" "$MNAME" text/plain

echo "=== 4. 清理旧资产（只留最近 $KEEP 份）==="
for prefix in dsh-qq- MANIFEST-; do
  api GET "/repos/$REPO/releases/$RID/assets?per_page=100" \
    | jq -r --arg p "$prefix" '.[] | select(.name|startswith($p)) | "\(.created_at)\t\(.id)\t\(.name)"' \
    | sort -r | tail -n +$((KEEP + 1)) | while IFS=$'\t' read -r _ id nm; do
        [ -n "$id" ] || continue
        api DELETE "/repos/$REPO/releases/assets/$id" >/dev/null
        echo "   删除 $nm"
      done
done

echo "=== 5. 远端现状 ==="
api GET "/repos/$REPO/releases/$RID/assets?per_page=100" \
  | jq -r '.[] | "   \(.name)\t\(.size) B\t\(.created_at)"' | sort
echo "完成：$NAME（$BYTES bytes）"
exit 0
