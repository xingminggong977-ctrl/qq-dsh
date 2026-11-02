# 计划与任务书 — 把 DSH 接入 QQ

## 交付物清单

```
qq-dsh/
├── DECISIONS.md        决策记录（已完成）
├── PROTOCOL.md         桥接协议契约 v1（已完成，两侧实现的集成边界）
├── PLAN.md             本文件
├── bridge/             T1 云端桥接服务（Node 24 原生，零运行时依赖）
├── node-plugin/        T2 本机 DSH `qq` profile 插件
├── nightly/            夜班：每晚 03:00 自我复盘，产出 memory / intent
├── persona/            她的人设、记忆、日记、想法（`xiaod-thoughts.md` 由 MC 侧写入）
├── pc-agent/           本机通道（`pc_exec/pc_read/pc_write` 的落地端）
├── bili-plugin/        B 站插件
├── whale-craft/        MC 第二现场：bot + viewer + 世界建造器（线上跑在 /opt/whale-craft）
└── deploy/             T3 部署 runbook + NapCat 配置 + 降风控清单
```

## 部署契约（v1，三份任务书共同遵守）

固定下列形状，使 T1 实现、T3 文档、T2 对接三者不必互相协商：

| 项 | 值 |
|---|---|
| 云端安装目录 | `/opt/dsh-qq-bridge` |
| 数据目录 | `/var/lib/dsh-qq-bridge`（`queue.db` + `blobs/`） |
| 运行用户 | `dshqq`（系统用户，无登录 shell） |
| systemd 单元 | `dsh-qq-bridge.service` |
| 入口 | `bin/bridge.js`，ESM，`#!/usr/bin/env node` |
| 监听 | `BRIDGE_HOST=127.0.0.1` + `BRIDGE_PORT=8787`，**绝不允许 0.0.0.0** |
| 环境变量文件 | `/etc/dsh-qq-bridge/env`（`EnvironmentFile=`，模式 0600） |

环境变量全集：`NAPCAT_WS_URL` `NAPCAT_ACCESS_TOKEN` `BRIDGE_HOST` `BRIDGE_PORT`
`NODE_TOKEN` `OWNER_QQ` `BACKLOG_TTL_MS` `DB_PATH` `BLOB_DIR`

**OneBot 连接方向**：NapCat 作 WS **服务端**，bridge 作 WS **客户端**连它。
理由：Node 24 内置 `WebSocket` 客户端，bridge 可以零依赖；反过来需要 WS 服务端，得引 `ws`。

**本机侧**：`ssh -N -L 127.0.0.1:8787:127.0.0.1:8787 <user>@<server>` 由 `deploy/tunnel.ps1`
守护（循环重连 + 退避），计划任务在登录时启动。本机插件直接访问 `http://127.0.0.1:8787`。

## 并行派发计划

| 任务 | 内容 | 依赖 | 可并行 |
|---|---|---|---|
| T1 | 云端 bridge | PROTOCOL.md + 部署契约 | ✓ |
| T2 | 本机 node 插件 | PROTOCOL.md + 部署契约 | ✓ |
| T3 | 部署 runbook | 部署契约 | ✓ |

三者互不共享文件，可同批派发。

## 验收计划（分层）

1. **单侧自检**（子代理负责）
   - T1：本地起假 NapCat（WS 服务端桩）+ 假 node（HTTP 客户端桩），验证入队/长轮询/租约重投/过期丢弃/图传/幂等。
   - T2：本地起假 bridge（HTTP 桩），验证 session 映射、串行、超时、结果回传、非 owner 无工具。
   - T3：runbook 每条命令在本机做语法/存在性核对；NapCat 安装步骤以官方文档为准，不编造。
2. **我复审**（R6）：读关键实现、跑两侧单测、对照 PROTOCOL.md 逐字段核对。
3. **本机端到端**：本机同时起 bridge（本地回环，不连真 NapCat）+ node-plugin，用假 NapCat 桩注入一条群消息，验证从"消息入队"到"agent 回复落库"的完整链路。
4. **云上端到端**：由用户照 runbook 执行——我无法验证，交付时明确标注为"未验证项"。

## 未验证/边界声明

- 云端部署、NapCat 真实登录、真实 QQ 收发：**只能由用户执行，我不宣称验证过**。
- 小号封号风险不因实现质量而消除，只能缓解。

---

## T1 任务书 — 云端 bridge

**目标**：实现 `qq-dsh/bridge/`，一个 Node 24 原生、零运行时依赖的服务：
连 NapCat 的 OneBot 11 WebSocket，把 QQ 消息落进 SQLite 队列，通过 HTTP 长轮询下发给本机节点，
收结果后回发 QQ；含鉴权、限流、过期丢弃、租约重投、图片 blob 存取。

**边界（只可动这些）**：`qq-dsh/bridge/**`。不得修改 `DECISIONS.md`/`PROTOCOL.md`/`deploy/`/`node-plugin/`。

**约束**
- 必须逐条实现 `qq-dsh/PROTOCOL.md` 的端点、字段名、状态码、语义；不得增删字段。
- 运行时依赖 **0 个**（`dependencies` 必须为 `{}`）。可用 `node:http`、`node:sqlite`、`node:crypto`、
  `node:fs`、内置 `WebSocket`/`fetch`。
- 只绑 `BRIDGE_HOST`，若配置成 `0.0.0.0` 必须启动即报错退出。
- 结构：`bin/bridge.js`（入口）+ `src/*.js`（模块化：onebot、queue、http、dispatch、ratelimit）+ `test/*.js`
- 一律 ESM（`package.json` 的 `"type":"module"`）。
- 不得把 `NODE_TOKEN`、`NAPCAT_ACCESS_TOKEN` 写进日志或错误响应。

**验收标准**
1. `node --test test/` 全绿。
2. 用假 NapCat WS 服务端桩注入一条群 @ 消息 → 落库 → 长轮询能取到，字段与 PROTOCOL.md 的 `Task` 完全一致。
3. 租约到期（`delivering` 超 `leaseUntil`）后重新可投递；同一 taskId 重复投递时 node 侧幂等由 T2 负责，
   bridge 侧对重复 `POST /node/result` 返回 `{"ok":true,"duplicate":true}`。
4. 超过 `BACKLOG_TTL_MS` 的 queued 任务不投递，且向 `replyTarget` 发固定文案
   「这条消息发出时我不在线，已经跳过了。有事再发一次。」
5. `401`：缺 Bearer 头、token 不匹配。`400`：缺必填字段。`404`：未知 taskId / blobId。
6. 图片：入队时下载到 `BLOB_DIR`，`GET /blob/<id>` 能原样取回。
7. 群消息非 @ 不入队；私聊一律入队；同 userId 每分钟 >6 次被丢弃并限流提示（5 分钟内最多提示一次）。
8. bridge 能作为 WS 客户端连上 NapCat 并正确解析 OneBot 11 事件（`post_type:"message"`、`message_type`、
   `message` 段数组、`sender.nickname`、`self_id`）。

**必须回报的证据**
- `node --test test/` 的完整输出（通过/失败数）
- `package.json` 里 `dependencies` 为空的证据（原文）
- 用假 NapCat 桩跑通"入队→poll→result→回发"的一次真实调用记录（打印的请求/响应）
- 测试覆盖不到的语义（例如真实 NapCat 行为）逐条列出，标明未验证
- 最终文件清单（`glob` 输出）

---

## T2 任务书 — 本机 DSH node 插件

**目标**：实现 `qq-dsh/node-plugin/`，一个注册进 DSH `qq` profile 的 cordis 插件：
出站长轮询云端 bridge 取任务，为每个 QQ 用户在 DSH 内维护独立 agent 会话，
把回复按 PROTOCOL.md 回传 bridge；非 owner 无法调用任何工具。

**边界（只可动这些）**：`qq-dsh/node-plugin/**`。可以在本机创建 `qq` profile
（`C:\Users\lenovo\.dsh\profiles\qq`）并挂载自己的插件，但**不得修改 `profiles\web` 或其任何文件**。

**约束**
- 逐条遵守 `qq-dsh/PROTOCOL.md` 的 Task 字段与 `/node/*` 端点语义。
- 插件形态参照实测样例：命名导出 `name` / `inject` / `apply(ctx, config)`，无 default export；
  参照 `C:\Users\lenovo\Documents\deepseek-harness\default-workspace\dsh-repro-kit\index.js:78,86`。
- 会话驱动必须用 `ctx.agents.createAgent` / `resume` + `agent.followup(createUserMessage(...))`，
  回复必须通过 `ctx.on('session/event', ...)` 自行聚合 assistant 文本——`followup` 返回 `void`，拿不到回复。
- 非 owner 必须走**无工具** preset，用 `CreateAgentOptions.meta.agentPreset` 与创建期 `setup` 钩子实现；
  这是硬需求。若 DSH 现有机制不支持"无工具 preset"，必须停下来回报，不得自行降级或跳过。
- 会话键、串行、并发上限 2、单轮超时 180s（线上 240s）、闲置 6 小时回收，均按 PROTOCOL.md。
- 图片经 `GET /blob/<id>` 拉取后转 image content block；单张 >4 MiB 丢弃并前置 `[图片过大已忽略]`。
- 断线（bridge 不可达）必须退避重连，不得进程退出、不得抛未捕获异常。
- 零运行时依赖优先；确实需要时在回报里说明理由。

**验收标准**
1. 用假 bridge HTTP 桩跑通：poll 拿到 Task → 建/续 session → 收到回复 → `POST /node/result` 正确。
2. 同一 session 键的消息串行；不同键可并发且不超上限 2。
3. 单轮超时 180s（线上 240s）后提交 `ok:false, error:"turn timeout"`。
4. 重复投递同一 taskId 只执行一轮，复用以有结果。
5. **非 owner 的会话调用任何工具被拒绝**——给出直接证据（构造一次工具调用尝试并展示被拒）。
6. bridge 不可达时插件存活，恢复后自动继续取任务（展示重连日志）。
7. `qq` profile 能启动并加载插件（`dsh --profile qq` 起来无报错）。

**必须回报的证据**
- 上述 1–7 每条的实测输出（贴关键行，不要整篇日志）
- 非 owner 无工具的实现代码片段 + 一次真实被拒的执行记录
- `C:\Users\lenovo\.dsh\profiles\qq\` 的挂载配置内容（cordis.patch.yml / package.json 的相关段）
- 未验证项清单（例如真实 QQ 环境下的表现）

---

## T3 任务书 — 部署 runbook

**目标**：产出 `qq-dsh/deploy/` 下用户可直接照做的部署材料：
NapCat 安装与登录、bridge 的 systemd 部署、本机 SSH 隧道守护、降封号清单、端到端联调步骤。

**边界（只可动这些）**：`qq-dsh/deploy/**`。不得改 `bridge/`、`node-plugin/`、协议与决策文档。
如果实现与文档对不上，回报而不是自己改对方。

**约束**
- 遵守上文「部署契约」的路径、单元名、用户、环境变量名。
- **不得编造命令**。NapCat 的安装方式以官方文档为准，先用 `web_search` 核实并给出**官方链接**；
  若官方提供多种方式，推荐一种并说明理由，其余作为备选一句话带过。
- 每条命令给出「预期输出/如何确认成功」，让非专家能自查。
- 阿里云安全组：明确说明**只需开 SSH(22)**，8787 不对外；写清为什么（bridge 绑回环 + SSH 隧道）。
- 降风控清单要具体可执行（养号期天数、每日消息量上限、禁止行为、IP 稳定性、掉线重启策略），
  不要泛泛而谈。
- 交付文件：`RUNBOOK.md`（主文档）、`env.example`、`dsh-qq-bridge.service`、
  `tunnel.ps1`（本机隧道守护，循环重连+指数退避）、`verify.ps1`（本机侧自检：隧道通不通、/health、取一件假任务）。

**验收标准**
1. 照 `RUNBOOK.md` 从空服务器到 bridge 起得来，每一步都有一条可复制命令 + 成功判据。
2. `dsh-qq-bridge.service` 语法正确（`systemd-analyze verify` 若可运行则给出结果；不可运行则说明）。
3. `env.example` 的键与部署契约**逐字一致**。
4. `tunnel.ps1` / `verify.ps1` 在本机 PowerShell 语法检查通过（`[scriptblock]::Create((Get-Content -Raw ...))`）。
5. NapCat 相关步骤带官方文档链接，且注明"版本可能变化，以官方为准"。
6. 明确列出**用户必须自己完成**、我无法代做的事项（扫码登录、安全组、QQ 号填写）。

**必须回报的证据**
- 文件清单 + 每个文件的用途
- NapCat 官方文档链接与核实到的安装方式（附搜索来源）
- 两个 ps1 的语法检查输出
- 你认为 runbook 里最可能出错的三步，以及为什么
