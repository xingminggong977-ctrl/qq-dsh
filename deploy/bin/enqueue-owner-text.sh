#!/bin/bash
# 把他让我转达的一段话，作为一条「主人在私聊里说的话」投进队列。
# 正文从文件读，避免中文、引号、换行在 argv 里被反复折腾。
set -u
TEXT_FILE=${1:-}
if [ -z "$TEXT_FILE" ] || [ ! -f "$TEXT_FILE" ]; then
  echo "用法：enqueue-owner-text.sh <正文文件>"
  exit 1
fi
node --input-type=module -e '
import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

const text = readFileSync(process.argv[1], "utf8").trim();
if (text === "") {
  console.log("正文是空的，不入队");
  process.exit(1);
}
const db = new DatabaseSync("/var/lib/dsh-qq-bridge/queue.db");
const src = db
  .prepare("SELECT * FROM tasks WHERE kind = ? AND is_owner = 1 AND result_ok = 1 ORDER BY created_at DESC LIMIT 1")
  .get("private");
if (!src) {
  console.log("没有可参考的历史私聊任务");
  process.exit(1);
}
const now = Date.now();
const row = { ...src };
row.task_id = randomUUID();
row.text = text;
row.images = "[]";
row.status = "queued";
row.lease_until = 0;
row.deadline_at = now + 30 * 60 * 1000;
row.created_at = now;
row.received_at = now;
row.updated_at = now;
row.result_ok = null;
row.result_text = null;
row.result_error = null;
row.result_at = null;
row.proactive = 0;
const keys = Object.keys(row);
db.prepare(`INSERT INTO tasks (${keys.join(",")}) VALUES (${keys.map(() => "?").join(",")})`).run(...keys.map((k) => row[k]));
console.log("已入队", row.task_id, "字数", [...text].length);
' "$TEXT_FILE"
