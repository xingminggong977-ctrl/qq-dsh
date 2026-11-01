# 夜班契约 v1

三端（挖矿器 / node-plugin / 部署脚本）共用。任何一端要改这里的路径或格式，必须三端一起改。

## 为什么要有夜班

白天她是「别人问什么答什么」，不会变强。真正让她变强的是**把当天真实的失败变成规则**——今天修好的四件事（ASR 缓存权限、内核僵死、转写失败丢原因、脏 UTF-8）没有一件是"反思"出来的，全是日志里的事实。

所以夜班 = 脚本挖事实（0 token）→ 一次受限复盘（一次轮次）→ 产出记忆补丁与代码意图（intent）。

## 铁律

1. **记忆可以自动写，代码只能提案/给意图。** 意图与提案都永不自动落地。
2. **解析失败 = 整轮产出作废，不重试。** 重试就是烧钱。
3. **挖矿那一步绝不调模型。** 90% 的活是 grep 和计数。
4. **夜班默认关闭。** `nightlyEnabled: false`，打开前先跑一晚 dry-run。
5. 她夜里说的话**不发给任何人**，除了 08:30 那条汇总。

## 文件位置（服务器）

| 用途 | 路径 |
|---|---|
| 审计流水 | `/opt/dsh-qq-agent/audit/audit-YYYY-MM.jsonl` |
| 她的记忆 | `/opt/dsh-qq-agent/persona/MEMORY.md` |
| 挖矿产出（清单） | `/var/lib/dsh-qq-agent/nightly/digest-YYYY-MM-DD.md` |
| 挖矿产出（计数） | `/var/lib/dsh-qq-agent/nightly/stats-YYYY-MM-DD.md` |
| 代码意图（intent） | `/opt/dsh-qq-agent/proposals/YYYY-MM-DD/NN-intent-M.json` |
| 代码提案（旧通道，停用） | `/opt/dsh-qq-agent/proposals/YYYY-MM-DD/NN-slug.patch` + `.json` |
| 夜班日志 | `/var/log/dsh-qq-nightly.log` |

日期一律**服务器本地日期**（Asia/Shanghai），不是 UTC。审计文件按 UTC 月分片，读的时候要按本地日期换算。

## digest 格式（挖矿器产出，node-plugin 消费）

最多 200 行 markdown，第一节标题固定为 `# 夜班素材 YYYY-MM-DD`，之后按小节组织：

```
## 概览
- private_reply 37 / proactive 13 触发 4 开口 / qzone_post 1
- 转写失败 4，投递失败 3，重试 3

## 异常
- [asr] 转写失败 4 次：PermissionError /home/dshqq/.cache —— 证据 05:57:22Z

## 重复问题
- 664671782 连问 3 次「在吗」未得到回应

## 她的回避
- 「不知道」2 次：「那个文件放哪了」

## 记忆现状
- MEMORY.md 39 行 / 上限 60
```

小节缺失是允许的，挖矿器有几项就写几项。**node-plugin 不许假设任何小节存在。**

## 夜班轮次的输出信封

模型必须只输出下面两种 fenced block，其余文字一律忽略：

````
```memory
- [w:4] 语音转写失败时要先查 transcribe.py 的 stderr 和 stdout 两边
```

```intent
file: node-plugin/lib/session.js
why: 03:12 的审计里 runTask 连续 3 次被 90s 上限杀掉，日志原文 "runTask timeout after 90000ms"
change: 把 runTask 的超时从硬编码 90s 改成读配置 taskTimeoutMs，默认值仍是 90000，线上行为不变
        超时后先把半截结果写进审计再抛错，避免整轮静默丢掉
        补一条超时路径的用例
verify: node --test test/session.test.js 全绿；再造一个 120s 的假任务确认它按新上限被杀
```
````

- `memory` 块：每行格式 `- [w:N] 文本`，N 是 1..5 的权重。
- `intent` 块：`file:` / `why:` / `change:` / `verify:` 四个字段，`change:` 允许续行。

### `intent` 是主通道

这一轮拿不到工具、看不到文件内容，所以它只陈述**意图 + 真实证据**，落地由早上的人和 agent 照做。四个字段全部必填，任一不合格**只丢这一条**（结果里记 `rejected` 及原因），其余条目和记忆照常写：

| 字段 | 要求 | 不合格 |
|---|---|---|
| `file:` | 必须命中 `NIGHTLY_FILE_HINTS` 里的真实路径 | 整条丢弃 |
| `why:` | 必须含至少一个具体证据：`HH:MM` 时间戳、日志原文片段、或审计数字 | 整条丢弃 |
| `change:` | 3–6 行中文，说明打算怎么改；可以提函数名，但**不要求精确** | 整条丢弃 |
| `verify:` | 说明怎么验证这次改动 | 整条丢弃 |

### 为什么改成 `intent`（三晚证据）

夜班这一轮 `isOwner:false` 且 `lockdownTools()` 把工具全撤，模型看不到任何文件内容。**看不见内容的模型写不出能应用的补丁**，这不是提示词能补救的，是契约错了：

- `proposals/2026-10-26` 三份的 `file:` 路径是编的（`agent/src/asr.js`、`bridge/src/delivery.js` 都不存在）。
- `proposals/2026-10-27` 两份路径对（`node-plugin/lib/session.js`），但 hunk 上下文是编的，`patch` 报 `Hunk #1 FAILED at 52`。
- `proposals/2026-10-28` 两份同样打不上，而且引用的 `const candidate = choose(ctx)`、`const text = await compose(task)` 在真实代码里根本不存在（`bridge/src/proactive.js` 里是 `queue.insertTask({ ... text: '' ...})`；`node-plugin/lib/runner.js` 里是 `this.#store.runTask(...)`）。

三晚 5 份提案，应用侧 **0 份能打上**。所以主通道换成 `intent`，并且 `file:` 只能从真实路径清单里选。

### 旧通道：`proposal`（unified diff）

`proposal` 块（`file:` / `why:` / `---` / unified diff）**保留可用但当前停用**：只有等夜班这一轮重新拿到读文件的工具、模型真能看到源码之后才该启用。现在它仍会被解析，两层兜底各自独立：块内 diff 畸形时按 `recountPatchHunks` 重算行数（不整轮作废）；块结构不成立（缺 `file:` / `why:` / `---`）时**只丢这一块**，原因进 `rejected`，同轮的记忆与意图照常写。

> 2026-10-28 改：结构不成立的 `proposal` 原本会作废整轮。否决理由——结构不成立的补丁根本不会写成 `.patch`，下游 `apply-proposal.sh` 连看都看不到，它没有能力伤到代码；而作废整轮的代价是确定的：一条旧通道的坏块能连带丢掉同一晚的记忆与意图，这正是 10-26/27/28 三晚「零产出」的事故形态。`apply-proposal.sh` 自己的预演 + 全量测试 + 备份回滚仍是补丁落地的唯一闸门。

两种通道可以混排在同一条回复里，数量合并计入上限。

## 硬上限

| 项 | 每晚 | 每周深度 |
|---|---|---|
| memory 行数 | ≤ 5 | ≤ 10 |
| MEMORY.md 总行数 | ≤ 60 | ≤ 60 |
| intent + proposal 条数 | ≤ 3 | ≤ 5 |
| 单条 diff 行数（仅 proposal 通道） | ≤ 120 | ≤ 200 |
| 单条 change 行数 | 3–6 | 3–6 |
| 轮次超时 | 120 秒 | 180 秒 |
| 输入 digest 行数 | ≤ 200 | ≤ 400 |

超出上限 → 整轮作废并记日志，不做截断（截断会产生半截 diff、半截意图）。

MEMORY.md 超 60 行时，**由写入方**按「权重最低、且最旧」的顺序挤掉旧行，直到回到 60 行以内。挤掉的动作要写一条 `memory_write` 审计。

## 时间表（服务器本地时间）

| 时刻 | 谁 | 干什么 |
|---|---|---|
| 03:00 | 挖矿器 timer | 生成 digest 与 stats |
| 03:10 | node-plugin | 夜班复盘轮次（一次） |
| 03:10 | node-plugin | 校验 + 写 MEMORY.md + 落提案文件 |
| 08:30 | 挖矿器 timer | 发一条 QQ 私聊汇总给主人（≤600 字） |
| 周日 03:00 | 同上 | digest 扩到 7 天，复盘走深度档 |

## 提案落地

`intent` 文件只是意图，不是补丁：夜班落成 `NN-intent-M.json`（`{ created, file, why, change, verify }`），早上照它改代码。

两个只读入口（不校验 root、不查 patch、不备份、不打补丁、不重启、不写任何源码文件）：

```bash
deploy/apply-proposal.sh --list-intents <提案目录>   # 一条一段，人可以直接照做
deploy/apply-proposal.sh --show-intent <x.json>      # 单份完整意图
```

`.patch` 提案的落地仍由 `deploy/apply-proposal.sh` 负责，它必须：备份 → 应用 → 跑全量测试 → 测试全绿才落盘并重启，否则回滚。

**夜班进程自己永远不落盘代码。**

## 关闭方式

配置里 `nightlyEnabled: false` 即时生效（下一次 timer 不再入队）；systemd 层用 `systemctl disable --now dsh-qq-nightly.timer` 彻底停。
