#!/bin/bash
# 只把**明确是长期要求**的那一条写进规矩文件；其余候选是任务、抱怨或上下文，不收。
set -u
FILE=/opt/dsh-qq-agent/persona/CORRECTIONS.md

if [ -f "$FILE" ]; then
  echo "规矩文件已存在，先看一眼："
  cat "$FILE"
fi

cat > "$FILE" <<'RULES'
- [2026-10-25] 他自己注意就行：爱国爱党、理性发言、适度玩梗，不要掺和男女对立
RULES

chmod 644 "$FILE"
echo "--- 写入后 ---"
cat "$FILE"

echo "--- 她下次装配提示词时会看到这一段 ---"
node --input-type=module -e '
import { QqPersona, trackQqSession } from "/opt/dsh-qq-agent/node-plugin/lib/persona.js";
const persona = new QqPersona({ personaDir: "/opt/dsh-qq-agent/persona", log: () => {} });
trackQqSession("qq-rules-probe", true);
const snapshot = persona.snapshot({ agent: { session: { id: "qq-rules-probe" } } });
const index = snapshot.text.indexOf("## 他给你立的规矩");
console.log(index < 0 ? "没有注入！" : snapshot.text.slice(index, index + 200));
console.log(`\n总字节 ${snapshot.totalBytes}`);
'
