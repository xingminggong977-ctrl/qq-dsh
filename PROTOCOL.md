# 桥接协议契约 v1

这份文件是 **bridge（云端）与 node-plugin（本机）之间的集成边界**。两侧由不同子代理实现，
任何一侧都不得单方面更改本文件定义的字段。改动需回到调度者。

## 拓扑与信任边界

```
QQ ←→ NapCat(云端, OneBot11 WS, 绑 127.0.0.1:3001)
        ↕ 本地 WS
     bridge(云端, HTTP, 绑 127.0.0.1:8787, node:sqlite 队列)
        ↕ SSH 端口转发 (本机主动出站: ssh -N -L 127.0.0.1:8787:127.0.0.1:8787)
     node-plugin(本机, DSH `qq` profile 内的 cordis 插件)
        ↕ agents.followup / ctx.on('session/event')
     本机文件系统
```

- bridge **只绑 `127.0.0.1`**，绝不监听 `0.0.0.0`。
- 隧道由本机的 SSH 客户端建立，方向是出站，因此本机无需公网 IP、无需内网穿透。
- 鉴权第二层：所有 `/node/*` 与 `/blob/*` 请求必须带 `Authorization: Bearer <NODE_TOKEN>`。
  `/health` 除外。缺头或值不符一律 `401`。

## 线上格式

- 请求与响应体均为 JSON（`Content-Type: application/json`），字段名固定，**不接受别名**。
- 时间戳一律 epoch 毫秒（`number`）。
- 未知字段必须被忽略（前向兼容）；缺必填字段返回 `400`。

## 端点

### `GET /health`
无鉴权。`200 {"ok":true,"queued":<n>,"uptimeMs":<n>}`

### `GET /node/poll?wait=<sec>&limit=<n>`
长轮询取任务。

- `wait` 默认 25，上限 30；`limit` 默认 2，上限 5。
- 有可投递任务立即返回；否则最多挂起 `wait` 秒后返回空数组。
- 鉴权失败 `401`。

响应 `200`：
```json
{ "tasks": [ Task, ... ] }
```

投递语义：被返回的任务在库里置为 `delivering`，附租约 `leaseUntil = now + 120000`。

### `POST /node/status`
body: `{ "taskId": string, "state": "accepted" | "running" }`

- `accepted`：node 已收到并接手 → 库置 `running`，租约延至 `now + 600000`。
- 幂等：同一 taskId 重复上报不报错。
- 未知 taskId → `404`。

响应 `200 {"ok":true}`

### `POST /node/result`
body:
```json
{ "taskId": string, "ok": boolean, "text": string, "error": string|null }
```

- `text` 为回给 QQ 的正文（node 已负责截断到 ≤ 8000 字）。
- **`text` 为空串 = 已读不回**：bridge 不发送任何 QQ 消息，任务直接置 `done`，
  例外：**主人私聊 + `needs_reply: true`** 时，空正文（含只有空白字符）会被替换成一句兜底
  `emptyReplyText`（默认「我在，你说。」），日志 `empty reply replaced with a fallback line`。
  2026-11-01 16:08 那次就是这样：空白正文被 NapCat 以 `retcode=1200` 拒发，对面十几秒什么都没看到。
  群里、`ask` 任务、`needs_reply:false` 的消息不受影响，仍然不发。
  且不计入频率限制。用于群聊上下文中「不需要她回话」的消息，以及她主动选择沉默。
- bridge 负责按 1800 字分段发回 `replyTarget`，每段之间 300ms。
- 发送失败重试 3 次（指数退避 1s/2s/4s），仍失败则记 `failed` 并写日志。
- 幂等：同一 taskId 重复提交，后者被忽略并返回 `{"ok":true,"duplicate":true}`。

响应 `200 {"ok":true}`

### `GET /blob/<blobId>`
返回图片二进制，`Content-Type` 取入库时记录的 `mime`。鉴权同上。
不存在 → `404`。

### 小结：node → QQ 的四条出站口

poll / status / result 是「她得到了一个任务」的路；下面四条是反过来——**她主动往 QQ 发东西**。
四条都只认主人（`OWNER_QQ` 的第一个），因为 bridge 上跑着 cron 和别的脚本，谁都能调就等于谁都能
以她的名义发消息。全部 `POST`，全部 `Authorization: Bearer <NODE_TOKEN>`。

| 路由 | body | 说明 |
|---|---|---|
| `/node/send` | `{ to, text, taskId? }` | 纯文本，`text` 先 `trim()`、1–2000 字（`TEXT_MAX_CHARS`）。带上 `taskId` 表示「这一轮她已经自己开口了」，bridge 会撤掉该任务还没发出的垫话（22/90/180 秒那三句） |
| `/node/send_image` | `{ to, file, kind? }` | 服务器上的图片路径，按扩展名白名单 + 10 MB 上限；`kind` 可 `private`/`group` |
| `/node/send_file` | `{ path, name? }` | 任意文件（PPT/PDF/表格），只发给主人；路径必须落在 `QQ_FILE_ROOTS` 里（软链接按 `realpath` 判），20 MB 上限，文件名里的路径分隔符会被抹掉 |
| `/node/remind` | `{ at, text, to? }` | `at` 是毫秒时间戳；落库后由 bridge 自己的 ticker 到点推 QQ，**不依赖 node 那一轮还活着**。同一目标 + 同一句话 + 5 分钟内 → 不重复存，返回 `{ ok: true, duplicate: true, reminderId }` |

三个发文件的共同点：NapCat 与 bridge 常常不在同一台机器上，所以一律把内容读成 `base64://` 再交给
OneBot，而不是给它一个本地路径。

### `POST /node/ask`
别人（微信桥、定时脚本、命令行）借她一张嘴问一句话，等一次完整回合。
body `{ text, from, images?, audios?, channel?, timeoutMs? }`，`from` 必填（要落进她的记忆里作身份），
`channel` ∈ `api` / `wechat`（`ASK_CHANNELS`），图片与语音走 base64，body 上限单给到 `ASK_MAX_BODY_BYTES`。
正文上限 `ASK_TEXT_MAX_CHARS` = 4000 字；超时被夹在 `DEFAULT_ASK_TIMEOUT_MS`（60 s）..`MAX_ASK_TIMEOUT_MS`（120 s）；调用方断开即作废等待项。

### `/node/pc/*`（主人电脑那一侧）
`POST /node/pc/heartbeat`、`POST /node/pc/poll`、`POST /node/pc/result` 由他电脑上的 `pc-agent`
长轮询驱动；`POST /node/pc/enqueue` 与 `GET /node/pc/status` 给插件用（`pc_exec` / `pc_read` / `pc_write`
和「他电脑在不在」）。协议细节见 `docs/pc-bridge-protocol.md`。

## Task 结构

```ts
interface Task {
  taskId: string            // UUID v4，bridge 生成
  kind: 'group' | 'private'
  groupId: string | null    // kind==='private' 时为 null
  userId: string            // 发言人 QQ 号
  nickname: string
  text: string              // 已剥离 @机器人 与 CQ 码的纯文本，可为空串（纯图消息）
  images: Array<{ blobId: string, mime: string, bytes: number }>  // 无图时为空数组
  receivedAt: number        // epoch ms
  deadlineAt: number        // epoch ms；now > deadlineAt 的任务不得投递
  isOwner: boolean          // bridge 依据 OWNER_QQ 白名单判定，node 不得自行改写
  mentioned: boolean        // v2：群消息是否 @ 了机器人；私聊恒 true
  needsReply: boolean       // v2：是否需要回复；私聊恒 true，群消息等于 mentioned
  proactive?: true          // 可选：bridge 自己造的任务（没有来信），见 v3 说明
}
```

**v3 字段：`proactive`（可选，只在为 `true` 时出现）。**
它不是一条来信，而是 bridge 在没有新消息时给她的开口机会（主动找他说话）。
`text` 为空、`userId` 是主人、`kind` 恒为 `private`。node 必须做三件事：不把它当作用户发言
塞进历史、把这一轮当作允许沉默（`allowEmpty`）、并且在模型回答 `NONE` 时提交**空正文**。
空正文在 `deliverResult` 里不会发出任何消息，所以「没话说」不花额度、不打扰人。
旧 node 不认识这个字段，只会把它当成一条空消息回一句「你想说什么」——因此**上线顺序是
先 node 后 bridge**。

**v2 字段的兼容规则**：`mentioned` / `needsReply` 可能不存在（旧 bridge）。
node 读到缺省必须按 `true` 处理——**缺字段等于要回复**，否则升级 bridge 前会静默不回话。

`replyTarget` 不下发——bridge 自己持有，node 不需要知道往哪回。

## 过期与重投

- 入队时 `deadlineAt = receivedAt + BACKLOG_TTL_MS`（默认 `1800000`，30 分钟）。
- `poll` 时若 `now > deadlineAt` 且状态为 `queued`：置 `expired`，**不投递**，
  由 bridge 主动向 `replyTarget` 发一条固定文案：
  `「这条消息发出时我不在线，已经跳过了。有事再发一次。」`
- **例外**：`needsReply:false` 的任务超期时**不发任何通知**，静默置 `expired`。
  上下文消息过期了再补一句「我不在线」只会刷屏。
- 租约到期（`delivering` 且 `now > leaseUntil`）：回到 `queued`，可被再次投递。
- node 必须按 `taskId` 幂等：同一 taskId 只执行一次 agent 轮次，重复投递直接复用已有结果。

## node-plugin 侧契约（不进 HTTP，但同属集成约束）

- 会话键：`qq:${kind}:${groupId ?? '-'}:${userId}`
- `isOwner` 决定 agent preset：`true` → 默认全权；`false` → 无工具的 `chat-only` 限制。
  **非 owner 的会话必须无法调用任何工具**——这是硬需求，不是尽力而为。
- 同一会话键串行执行；跨会话全局并发上限默认 2。
- 单轮超时默认 180s，超时提交 `ok:false` + `error:"turn timeout"`；线上 profile 设成 240s。
  超时前她已经说出口的话会被保住：先发那一段（`earlyReplyMs` / `earlyReplyMinMs`），再追一句「交代结果」，
  最后才按超时上报；确实什么都没说，才由 bridge 补一句「你说句「继续」」。
- 一个回合最多 20 次工具调用（`toolCallBudget`），到量同样先追收尾话，再以 `ok:true` 交付已说的部分。
- 会话闲置 6 小时回收（`dispose()` 并移除映射）。
- 图片：node 用 `GET /blob/<blobId>` 拉取后作为 image content block 传给 agent；单张上限 4 MiB，
  超限时该图被丢弃并在 `text` 前置一行 `[图片过大已忽略]`。

## OneBot 侧约束（bridge 内部，但属对外行为，同样固定）

- **方向固定**：NapCat 作 WS **服务端**，bridge 作 WS **客户端**。不接受反过来的配置。
- `NAPCAT_WS_URL` 默认 `ws://127.0.0.1:3001/`。bridge 必须用 URL 解析器处理，
  路径原样用于 WS upgrade；用户填不填结尾的 `/` 都必须能连上。
- **access_token 双通道发送**：连接时**同时**在 `Authorization: Bearer <token>` 头和
  `?access_token=<token>` 查询参数里携带 `NAPCAT_ACCESS_TOKEN`（为空时两者都不发）。
  理由：NapCat 不同版本/配置认其中一种，只发一种会造成"值明明一致却连不上"的排查黑洞。
- 群消息入队策略由 `GROUP_MODE` 决定：
  - `mention`（默认）：仅 `@机器人` 时入队（`needsReply:true`），其余丢弃。
  - `all`：群消息全部入队；没 @ 的带 `needsReply:false`、`mentioned:false`，
    只作为群聊上下文，不触发回复。
- 私聊消息一律入队，`mentioned:true`、`needsReply:true`。
- **段类型不许把消息吃成空串**：`text` / `at` / `reply` 之外，卡片与文件类段落转成可见占位——
  `json` `xml` → `[卡片消息]`、`forward` → `[合并转发]`、`share` → `[链接分享]`、`music` → `[音乐分享]`、
  `file` → `[文件]`、`poke` → `[戳一戳]`、`dice` → `[骰子]`、`rps` → `[猜拳]`；没见过的类型变成 `[类型名]`。
  以前这些段被直接丢掉，他发一张卡片过来，她看到的是「消息是空的」，还会以为自己收了个空包。
- 频率限制：同一 `userId` 每分钟最多 6 次入队，超出则丢弃并回一句限流提示（每 5 分钟最多提示一次）。
  已读不回（空 `text`）不占用这个额度。
- `GROUP_MODE` 取值非法时，bridge 必须**启动即报错退出**，与 `BRIDGE_HOST` 同等级处理。
- `BRIDGE_HOST` 解析为 `0.0.0.0` 或 `::` 时，bridge 必须**启动即报错退出**，不得降级为警告。

## v2：群聊上下文与插话

群不是「一堆私聊」，而是一段连续的对话。只丢给她被 @ 的那一句，她永远听不懂
「这个」「那个」指什么。所以 v2 让群消息全部进来，但**进来 ≠ 回话**。

- **上下文缓冲**：node 按会话键维护每群最近 **20 条**消息 `{nickname, text, mentioned, at}`。
  `needsReply:false` 的任务只进缓冲、立刻回 `text:''`，不跑 agent 轮次——**不花 token**。
- **前文注入**：`needsReply:true` 的任务在送进 agent 前，把缓冲格式化成
  「群聊前文」文本块拼在用户这句话之前，被 @ 的条目前缀 `@`。
- **插话（默认关闭）**：`proactiveInterjection.enabled` 为 `false` 时，绝不主动发言。
  开启后受三重配额约束：`minIntervalMs`（默认 20000）、`maxPerMinute`（默认 6）、
  `maxPerGroupPerDay`（默认 100）。agent 回空串或 `[沉默]` 表示这一轮不发声。

**为什么默认关**：新号第 1 天在群里主动找陌生人说话，是这套体系里最容易被风控
盯上的单一行为。收敛期（见 `deploy/RUNBOOK.md` §15.1.3）P0 期间主动发言额度是 0 条。
开关留给使用者，默认值按安全的那边设。

**`needsReply` 只控制两件事**：是否触发 agent 轮次、超期时是否通知。它**不控制投递**。
插话时 node 会挑一条上下文任务作为载体提交非空 `text`，bridge 必须照发——
如果 bridge 按 `needsReply:false` 拦投递，插话就永远说不出来。

**不设群白名单**（2026-10-25 决）：任何群任何 @ 都回。安全性不依赖白名单——
群里的人都是非 owner，`isOwner:false` 的会话拿不到任何工具，这是代码级约束。
