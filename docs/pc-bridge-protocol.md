# PC 工具通道协议 v1（D17）

她是云端的，电脑是你家的。**云端永远不主动连你的电脑，也绝不开入站端口。**
PC 端 `pc-agent` 主动长轮询云端 bridge；命令向下走，结果向上走。

```
她 ──pc_exec──▶ node-plugin ──HTTP──▶ bridge ──(队列)──▶ pc-agent ──▶ 本机执行
                                        ▲                    │
                                        └────── result ◀─────┘
```

三个进程，三份代码，一个契约。本文件就是那个契约，**改动必须同步三边**。

## 0. 传输

- bridge 监听 `BRIDGE_HOST:BRIDGE_PORT`（线上 `127.0.0.1:8787`，不对外）。
- pc-agent 自己维护一条 SSH 隧道连过来：
  `ssh -N -L 18787:127.0.0.1:8787 root@203.0.113.11`
  然后访问 `http://127.0.0.1:18787`。隧道由 pc-agent 拉起并看守，断了重连。
- 鉴权：所有 `/node/pc/*` 走现有 `Authorization: Bearer <NODE_TOKEN>`（`bridge/src/http.js:221` 的 `needsAuth` 已覆盖 `/node/` 前缀，路由加在 `/node/pc/` 下自动继承）。
- 编码：`Content-Type: application/json`，UTF-8。

## 1. 端点

### `POST /node/pc/heartbeat` — pc-agent 报到

```json
{ "agentId": "pc-lenovo", "hostname": "LENOVO", "platform": "win32", "version": "1.0.0",
  "capabilities": { "exec": true, "read": true, "write": true },
  "policy": { "roots": ["C:\\Users\\lenovo\\Documents", "..."], "execAllow": ["dir", "git"] } }
```

响应 `{ "ok": true, "now": 1690000000000, "serverVersion": "1" }`。
心跳每 **10s** 一次，与 poll 相互独立（长轮询阻塞时心跳照走）。

### `POST /node/pc/poll` — 取一条命令（长轮询）

请求 `{ "agentId": "pc-lenovo", "waitSeconds": 25 }`（`waitSeconds` 夹在 1..30）。

有命令：`{ "ok": true, "command": { "id": "c_01H...", "kind": "exec", "deadlineAt": 1690000030000, "payload": { ... } } }`
无命令：`{ "ok": true, "command": null }`

`payload` 按 kind：

| kind | payload |
|---|---|
| `exec` | `{ "command": "git status", "cwd": "C:\\...\\repo", "timeoutMs": 30000 }` |
| `read` | `{ "path": "C:\\...\\a.md", "maxBytes": 65536 }` |
| `write` | `{ "path": "C:\\...\\a.md", "content": "…", "append": false }` |

### `POST /node/pc/result` — 回结果

```json
{ "id": "c_01H...", "ok": true, "exitCode": 0,
  "stdout": "…", "stderr": "", "truncated": false,
  "bytes": 1234, "durationMs": 812,
  "error": null, "errorCode": null }
```

失败时 `ok: false` 且 `errorCode` ∈ `not_allowlisted` | `path_denied` | `timeout` | `spawn_failed` | `too_large` | `internal`，`error` 是给人看的中文一句。
响应 `{ "ok": true, "accepted": true }`；**重复 id 返回 `accepted: false`**（幂等，丢重放）。

### `POST /node/pc/enqueue` — node-plugin 提交并等待

请求 `{ "kind": "exec", "payload": { ... }, "timeoutMs": 30000 }`（`timeoutMs` 夹在 1000..120000，默认 30000）

响应二选一：

```json
{ "ok": true,  "id": "c_01H...", "state": "done", "result": { ...同 result 体... } }
{ "ok": false, "id": "c_01H...", "state": "offline"|"timeout"|"busy",
  "error": "电脑没开着，或 pc-agent 没在跑", "lastSeenSeconds": 412 }
```

`state` 语义（node-plugin 只用这三个 + done）：

- `done` — 拿到了 result（**result.ok 可能是 false**，那是执行失败，不是通道失败）
- `offline` — 心跳已过期，命令根本没发出去
- `timeout` — 命令发出去了，但没在 `timeoutMs` 内回来（可能正忙，也可能刚断）
- `busy` — 在途命令已达上限（4 条）

### `GET /node/pc/status` — 三态

```json
{ "ok": true, "state": "online", "agentId": "pc-lenovo", "hostname": "LENOVO",
  "lastPollSeconds": 2, "lastHeartbeatSeconds": 9,
  "capabilities": { ... }, "policy": { ... }, "queued": 0, "inflight": 0 }
```

| state | 判据 | 她该怎么说 |
|---|---|---|
| `online` | `lastPollSeconds ≤ 10` | 正常用 |
| `just_lost` | `10 < lastPollSeconds ≤ 120` | 「电脑刚断开，可能正在重连，你再等等」 |
| `offline` | 超过 120s 或从未报到 | 「电脑没开着」 |

## 2. bridge 内部规则

- 队列**纯内存**，不落库（命令是短命的，两边都在线才有意义）。重启即丢，可接受。
- 在途上限 **4**，待取上限 **16**，满了 `enqueue` 回 `busy`。
- 每条命令 `deadlineAt = now + MAX(timeoutMs, 0) + 5000` 宽限；过期没人取就丢弃，等待方按 `timeout` 收场。
- 结果体截断：`stdout` / `stderr` 各留 **最后 64KB**，置 `truncated: true`。
- 请求体上限 **1.5MB**（`write` 的 content 最大 1MB）。
- 服务端**只搬运不校验业务**：只验 `kind`、字段类型、长度上限。路径白名单与命令白名单在 pc-agent 本地执行——`server never executes`。
- 等待方断开（客户端 AbortSignal）→ 命令作废，不留垃圾。

## 3. pc-agent 本地策略（安全边界在这里）

**路径**：先 `fs.realpath`（解开符号链接），再判是否落在某个 root 内；大小写不敏感、分隔符归一化。
默认四个 root（用户定）：

```
C:\Users\lenovo\Documents      （工作区就在里面）
C:\Users\lenovo\Desktop
C:\Users\lenovo\Downloads
```

硬拒（即使落在 root 内也拒）：`.ssh`、`.dsh`、`.gnupg`、`.aws`、`.azure`、`.git-credentials`、`.npmrc`、`.netrc`、`AppData`、`.config`。
`write` 额外拒 `*.exe`/`*.dll`/`*.bat`/`*.ps1`/`*.cmd`/`*.msi` 与所有 `.git` 目录内容。

**命令**：默认白名单（用户定「一组常用安全命令」）：

```
dir  type  where  findstr  git  node  python  py  npm
Get-ChildItem  Get-Content  Get-Location  Get-Date  Get-Process
Test-Path  Select-String  Resolve-Path  Get-ChildItem
```

- 首 token（去 `.exe`、小写）必须在白名单里，否则 `not_allowlisted`。
- **永不使用 `shell: true`**。白名单里的 exe（`where`/`findstr`/`git`/`node`/`python`/`npm`）直接 `spawn(exe, argv, { shell: false })`。
- cmd 内建（`dir`/`type`）与 PowerShell cmdlet 走 `cmd.exe /d /s /c` 或 `pwsh -NoProfile -NonInteractive -Command`，但**先把整条命令做词法检查**：任何 token 命中 `; & | > < ^ ` $( %~` 中任一个 → `not_allowlisted`（不做多命令编排）。
- 高危参数一律拒：`node`/`python` 的 `-e`/`--eval`/`-c`/`-m`；`git` 的 `-c`/`--exec-path`/`--upload-pack`/首位置为 `!` 开头；`npm` 只允许 `ls`/`view`/`--version`。
- 单条超时 30s（上限 120s），超时杀进程树，`errorCode: 'timeout'`。
- 输出各留最后 **32KB**，置 `truncated`。
- `cwd` 也必须在 roots 内，默认 `C:\Users\lenovo\Documents`。

## 4. node-plugin 侧

- 三个工具：`pc_exec(command, cwd?)`、`pc_read(path)`、`pc_write(path, content, append?)`。
- 只开给主人（`session private + isOwner`）——群里不给。复用现有 owner 判定，不新造机制。
- 配置：`pcEnabled`（默认 false）、`pcBaseUrl`（默认 `http://127.0.0.1:8787`）、`pcTimeoutMs`（默认 30000）。
- 工具描述里必须写清「电脑没开着」与「刚断开」的区别，让她会说人话而不是干等。
- `offline` → 工具返回「PC 没开机（最后心跳 7 分钟前），这条命令没发出去」；`timeout` → 「电脑开着但 30 秒没回话，可能在忙」。
