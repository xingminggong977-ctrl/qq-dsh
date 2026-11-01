#!/bin/bash
# 把历史上「他真正说过的那些要求」翻出来，先只看不写。
# 判断用的是线上同一份 lib/correction.js，不是另写一套规则。
set -u
node --input-type=module -e '
import { DatabaseSync } from "node:sqlite";
import { isCorrection, normalizeCorrection } from "/opt/dsh-qq-agent/node-plugin/lib/correction.js";

const db = new DatabaseSync("/var/lib/dsh-qq-bridge/queue.db");
const rows = db
  .prepare("SELECT text, received_at FROM tasks WHERE is_owner = 1 AND kind = ? AND text <> ? ORDER BY received_at ASC")
  .all("private", "");
const hits = [];
const seen = new Set();
for (const row of rows) {
  if (!isCorrection(row.text)) continue;
  const body = normalizeCorrection(row.text);
  if (body === "" || seen.has(body)) continue;
  seen.add(body);
  hits.push({ at: new Date(row.received_at).toISOString().slice(0, 10), body });
}
console.log(`主人私聊消息 ${rows.length} 条，其中像「要求」的 ${hits.length} 条：`);
for (const hit of hits) console.log(`  ${hit.at}  ${hit.body}`);
'
