#!/bin/bash
# 把她写在 workspace 里的日记并入正式日记目录。
#
# 为什么要这一步：DSH 的文件沙箱只允许她写 workspace，/opt/dsh-qq-agent/persona/
# 是只读的——这是故意的，她不该能改自己的记忆文件。代价是她写完日记需要有人搬。
# 这个脚本就是那个「人」，每小时跑一次。
#
# 幂等性靠「先追加、再把源文件挪进 merged/」：崩在两步之间最坏是多一次追加，
# 而挪走之后的文件不会再被扫到。
set -u

PENDING=${PENDING_DIR:-/var/lib/dsh-qq-agent/workspace/persona-pending}
DIARY=${DIARY_DIR:-/opt/dsh-qq-agent/persona/diary}
MERGED=$PENDING/merged
LOG=${MERGE_LOG:-/var/log/dsh-qq-diary-merge.log}

mkdir -p "$MERGED" "$DIARY"

shopt -s nullglob
files=("$PENDING"/*.md)
if [ ${#files[@]} -eq 0 ]; then
  exit 0
fi

stamp=$(date -Is)
for src in "${files[@]}"; do
  name=$(basename "$src")
  # 文件名前缀是日期；没有就用文件的修改日期，总比丢掉好。
  date=$(printf '%s' "$name" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
  if [ -z "$date" ]; then
    date=$(date -r "$src" +%Y-%m-%d)
  fi
  dest="$DIARY/$date.md"

  # 去掉开头的大标题与那段说明引用，只留正文。
  body=$(awk 'BEGIN{skip=1} skip==1 && (/^#/ || /^>/ || /^[[:space:]]*$/) {next} {skip=0; print}' "$src")
  if [ -z "$body" ]; then
    echo "$stamp $name 没有正文，跳过" >> "$LOG"
    continue
  fi

  cp "$dest" "$dest.bak.$(date +%H%M%S)" 2>/dev/null
  printf '\n%s\n' "$body" >> "$dest"
  mv "$src" "$MERGED/$name.merged-$(date +%H%M%S).md"
  echo "$stamp 并入 $name -> $dest ($(printf '%s' "$body" | wc -c) 字节)" >> "$LOG"
done

# 日志轮转，只留最近 1000 行。
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
