# 决策记录 — 把 DSH 接入 QQ

生成于 2026-10-19。记录已敲定的决策与理由，供后续返工时判断"这条能不能改"。

## 目标

把 DSH agent 接入 QQ：在 QQ 里发消息，由 DSH 上的 agent 处理并回复；用于用户本人和几个朋友的小群。agent 需要能操作**用户本机 Windows** 上的文件。

## 已敲定的决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | 接入通道用 **NapCat / OneBot 11** | 能力最全（私聊、群聊、图片），改造成本最低。用户已知悉属非官方协议、有封号风险。 |
| D2 | 用**专用小号**登录协议端 | 风控命中时只损失小号，不波及主号的社交关系与资产。 |
| D3 | 使用对象是**用户本人 + 几个朋友的小群** | 需要区分发言人、每用户独立会话、限流。 |
| D4 | 能力不设限，但**执行类操作只给 owner** | 用户最初选"完全同权"，澄清后确认"能力上限不变、只授予 owner"。非 owner 只能聊天答疑。理由：非 owner 若能驱动工具，等于他们能操作本机任意文件（含凭证）。 |
| D5 | 拓扑：**NapCat + bridge 常驻阿里云 Linux，DSH 留本机** | 用户在"本机休眠"与"操作本机文件"之间选了"云端常驻 + 消息排队补答"。NapCat 在云端 → 小号 7x24 在线不掉线；DSH 在本机 → 原生操作本机文件。 |
| D6 | 单独开 **`qq` profile** | QQ 的会话、工作区、凭证与日常 web profile 隔离，互不污染。 |
| D7 | 积压消息**超时丢弃**，回一句"当时不在线" | 默认阈值 30 分钟。避免开机瞬间被几小时前的问题刷屏，也避免 agent 对着过时上下文干活。 |
| D8 | 群聊必须 **@机器人** 才响应；私聊直接响应 | 防止群里的闲聊全部触发 agent 与计费。 |
| D9 | per-user 会话，闲置 **6 小时**回收 | 每人独立上下文；避免 session 无限增长。 |
| D10 | v1 支持**文本 + 图片**进 vision，**语音不做** | 语音的转写链路（whisper/sherpa）是独立工程量，且群里语音需求未验证。 |
| D11 | 云端部署**原生 Node + systemd**，不用 Docker | 本机无 Docker/WSL，容器层我只能盲写不能测。原生路径本地可完整验证，与云端一致。 |
| D12 | 本机↔云端走 **SSH 端口转发**，bridge 只绑 `127.0.0.1` | 免域名、免 TLS 证书、不对公网开端口；加密与身份复用 SSH。本机休眠即断，醒来重连自动拉队列，"排队补答"是隧道+队列的天然行为。 |
| D13 | bridge **零运行时依赖**（`node:http` + `node:sqlite`） | Node 24 自带 `node:sqlite`；少一层供应链，云上只需装 Node。 |
| D14 | 队列语义 **at-least-once**，node 按 `taskId` 幂等去重 | 本机网络/休眠会导致租约超时重投；至多一次的"丢任务"比"重复执行一次只读回复"更糟。 |
| D15 | 小号认定为**活跃号**，跳过"唤醒"环节；但挂 NapCat 后**前 14 天只收不发**再逐步放开 | 用户确认该号注册一年且一直在用（手机上常登着）。风控看近期行为连续性而非账号年龄，因此剩余主要风险是"机房 IP 长期在线"这一项，用只收不发+固定 IP+低频率逐步放大来稀释。 |

## 被排除的方案

- **全在本机**（NapCat + DSH 都在 Windows）：最简单、封号风险最低，但本机休眠时 QQ 侧完全无响应。用户明确否掉了"休眠时不响应"。
- **云端也跑一套 DSH 兜底聊天**：要维护两套 agent、两套凭证、一条切换逻辑，收益不抵复杂度。
- **frp / WireGuard 通用隧道**：应用层用 SSH 端口转发已经够用，多引入一个组件没有收益。

## 已知风险（需用户知情）

1. 小号在**机房 IP** 长期登录，封号风险显著高于家宽。缓解措施见 `deploy/RUNBOOK.md` 的养号与降风险清单。万一被封需换号重来。
2. 本机休眠期间收到消息不会即时答复（按 D7 超时丢弃）。
3. 用户**不上云操作**（选择"你自己执行，我给命令和配置文件"），所以云端部署由用户照 runbook 执行，我只能对配置与命令做静态审查 + 本机端到端验证。

## 未决/待收集

- 用户 QQ 号（owner 白名单）— 部署时填 `.env`
- NapCat 小号首次登录需扫码 — 用户手工完成
- 小号 QQ 号本身 — 装完 NapCat 扫码后才确定
- ~~阿里云实例的发行版与规格~~ — 已确认：Ubuntu 22.04 64 位、`ecs.e-c1m2.xlarge`（4 核 8 GiB）、系统盘 20 G、5 Mbps 按流量、华东1（杭州）、`root@203.0.113.11`

---

## 验收记录（三份工件均已通过）

| 工件 | 位置 | 验证方式 | 结果 |
| --- | --- | --- | --- |
| T1 云端 bridge | `qq-dsh/bridge/**` | 我亲跑 `node --test test/` | 55/55 pass，EXIT=0，`dependencies: {}` |
| T2 本机 node-plugin | `qq-dsh/node-plugin/**` | 我亲跑 `npm.cmd test` | 16/16 pass，EXIT=0 |
| T3 部署 runbook | `qq-dsh/deploy/RUNBOOK.md` | 逐条核对过期表述 | 1213 行，6 个过期词 0 命中 |
| 人格层 | `qq-dsh/persona/{PERSONA,MEMORY}.md` | 我亲写，node-plugin 只读 | 经 `systemPrompt.section()` 注入，`interpolate: false` |

bridge 的全链路已有覆盖：`qq-dsh/bridge/test/e2e.test.js:16` 测 `napcat -> sqlite -> poll -> result -> QQ`，用假 OneBot WS 服务端 + 真实 sqlite。无需在本机另做一次云端联调。

### 本机环境坑（不影响云端，但会影响本机步骤）
- **PowerShell 执行策略禁用 `npm.ps1`**：`npm test` 报 `cannot be loaded because running scripts is disabled`，必须用 `npm.cmd test`。node-plugin 的 README 尚未收录此条，属已知缺口。
- 本机 PowerShell 是 **5.1.26100.9711**，没有 pwsh 7：`deploy/tunnel.ps1`、`deploy/verify.ps1` 按 5.1 语法写（禁三元、禁 `??`）。
- 本机 `curl raw.githubusercontent.com` 失败（`curl: (7)`），我这边抓不到 NapCat 官方页面正文；云端网络状况另测，不要照搬此结论。

### 下一步（用户动作）
1. 跑 `RUNBOOK.md:119` 的 S1 体检命令块，把输出贴回来
2. S2–S9 在云端，S10–S13 在本机
3. S8 之后进入 14 天 P0 收敛期：只收不发、不拉群、≤50 条/天

### S1 体检结果（已收到）

| 项 | 实测 | 判据 | 结论 |
| --- | --- | --- | --- |
| 系统 | Ubuntu 22.04.5 LTS (Jammy) x86_64 | 需 x86_64 | 过 |
| glibc | 2.35（Ubuntu GLIBC 2.35-0ubuntu3.15） | ≥ 2.28 | 过，可直装 Node 24 官方二进制 |
| CPU | 4 | — | 过 |
| 内存 | total 7522 MB / available 6782 MB | ≥ 1 GB | 过，余量充足 |
| 磁盘 | `/dev/vda3` **40 G，已用 5.6 G，可用 32 G** | ≥ 5 GB | 过 |
| Docker | **NO_DOCKER** | — | **走裸机安装器路线，不是默认的 Docker 路线** |
| Node | NO_NODE | — | 需 S3 安装 |

**两处事实纠正**
1. **磁盘是 40 G 不是 20 G**。控制台里 `ubuntu_22_04_x64_20G_alise_20260916.vhd` 的 "20G" 是镜像模板名，不是实际容量；`df -h` 的 40 G 才是真相。此前"盘紧张、需定期清 Docker 日志"的提醒作废，可用 32 G 绰绰有余。
2. **没有 Docker** → runbook 里刚改成"默认为 Docker"的那段要翻回裸机路线。当时把 Docker 设为默认的理由只是"8 G 内存无资源顾虑"，不是实测过存在。

**遗漏未回**：`systemctl --version | head -1` 与 `timedatectl | head -3` 的输出被截图截断。Ubuntu 22.04 阿里云镜像必然带 systemd，S2 的 `systemctl daemon-reload` 会立刻暴露问题，故不再单独追问。

### S1.5 网络探测结果 → 路线定案

| URL | 状态 | 耗时 | 判读 |
| --- | --- | --- | --- |
| `https://nodejs.org/dist/index.json` | 200 | 4.464 s | 通但慢 |
| `https://registry.npmmirror.com/-/binary/node/` | 200 | 0.177 s | 通且快 25 倍 → **Node 走这里** |
| `https://mirrors.aliyun.com` | 301 | 0.084 s | 通（跳转正常） |
| `https://github.com` | 200 | 0.728 s | 通 → **NapCat 走 GitHub 裸机安装器** |
| `https://registry-1.docker.io/v2/` | **000** | 4.202 s | **连不上 → Docker 路线死路** |

apt 源：`mirrors.cloud.aliyuncs.com/ubuntu jammy {main,restricted,universe}`（阿里云内网镜像，装包很快）。
系统：systemd `249 (249.11-0ubuntu3.23)`；`timedatectl` 三者一致，时间已同步。

**D16 路线定案**
- Node 24：**npmmirror 二进制 + SHASUMS256 校验**，装到 `/usr/local/lib/nodejs/node-<VER>-linux-x64`，`bin/*` 全量 symlink 到 `/usr/local/bin`
- NapCat：**裸机安装器（GitHub）**，不用 Docker
- 理由：Docker Hub 返回 000 是硬事实；nodejs.org 虽通但 4.46 s，二进制几十 MB 会拖很久，而 npmmirror 有官方 SHASUMS 可校验，速度和安全都不亏

### runbook 已对齐本机实测（验收通过）
`deploy/RUNBOOK.md` 1213 → **1277 行 / 63055 B**，结构完好（fence 98，偶数）。
- Docker 从「默认」降为「本机不可用，仅留档」：`RUNBOOK.md:543` 裸机安装器为唯一主路径、`:617` §8.4 带 `000` 证据
- 容量按 `df -h` 的 40 G 写，`RUNBOOK.md:194` 新增 §2.3 专门解释镜像名里的 `20G` 只是模板编号
- S3 换成 npmmirror 脚本，`RUNBOOK.md:270-291` 与我交付的脚本 SHA256 一致（`25ac3ef4…eaf815`）
- S1 改为实测记录 + 5 行网络探测表（`RUNBOOK.md:177-181`，docker 行为 `000`）

**我亲手修的 3 处陈旧表述（R8 极小单点改动，非派发）**
- `RUNBOOK.md:596-597` §8.3 验收命令去掉 `docker ps` 前半段 → `ps -ef | grep -i [n]apcat`
- `RUNBOOK.md:1148` §15.5 周检第 4 条：`docker ps` 的 STATUS → `systemctl show -p ActiveEnterTimestamp`
- `dsh-qq-bridge.service:33` 注释「未知发行版」→ 已确认为 Ubuntu 22.04.5
（§15.5 属原禁令范围，但禁令本意是护住 P0/P1/P2 纪律，不含一条失效的诊断命令；只替换该行命令，纪律正文未动。）

### 部署进度（用户在执行）
S1 体检 ✅ · S1.5 网络探测 ✅ · S3 Node 24(v24.22.1) ✅ · S2 用户与目录 ✅
**S4 上传 bridge —— 完成**：`deploy/bridge.tar.gz` 30537 B / 33 entries / 无 node_modules；scp 到 `/tmp/` 后在 `/opt/dsh-qq-bridge` 解包，`node --test test/index.js` 在真 Ubuntu 上 **55/55 通过**。

---

## 全链路打通（2026-10-25）

链路：`QQ → NapCat(OneBot11 WS 服务端 127.0.0.1:3001) → bridge(127.0.0.1:8787, SQLite 队列) → SSH 隧道 → 本机 node-plugin → DSH agent → 回复回 QQ`

**实测证据链**
| 环节 | 证据 |
|---|---|
| NapCat 登小号 | 日志 `WebSocket服务器 dsh-bridge -> 127.0.0.1:3001`，`ss` 见 `127.0.0.1:3001` |
| bridge 连上 NapCat | `{"level":"info","msg":"napcat websocket connected","url":"ws://127.0.0.1:3001/"}`（此前重连 33 次后自动恢复，退避重连有效） |
| 消息进队列 | 大号发私聊后 `{"ok":true,"queued":1,"uptimeMs":83739}` |
| 隧道通 | 本机 `http://127.0.0.1:8787/health` → `{"ok":true,"queued":1,...}` |
| node 取任务并回话 | `polling ...` → `created owner session qq-d3be3f79-…` → `persona: loaded 2235 bytes, memory 393/8192, diary 0d, total 2645/16384` → `result 7c3f2c0d-… ok` |

**部署期间踩到的 4 个坑（均已修复，写进 runbook 时应保留）**
1. **queue.db 归属 root**：S4 用 root 跑 `node --test` 时未加载 env，`config.js` 走默认 `DB_PATH=/var/lib/dsh-qq-bridge/queue.db`，以 root 建库；服务以 `dshqq` 运行 → `attempt to write a readonly database`。修复 `chown -R dshqq:dshqq /var/lib/dsh-qq-bridge`（含 `blobs/`、`-wal`、`-shm`）。
2. **WebUI 绑公网**：`webui.json` 默认 `"host": "::"` → `ss` 显示 `*:6099`，WebUI 可接管 QQ。改 `127.0.0.1`，需要时走隧道 `-L 6099:127.0.0.1:6099`。
3. **OneBot 配置不生效的真因是「没登录」**：`onebot11_10002.json` 写入后 `3001` 不监听，一度怀疑字段名猜错；实际是 QQ 重启后掉登录停在扫码界面，OneBot 服务要等登录成功才启动。登录后立即可用。
4. **GitHub raw 全线不可达**：`raw.githubusercontent.com` 与 `cdn.jsdelivr.net` 均 `Connection reset by peer`，`raw.gitmirror.com` DNS 失败。实测最快 `gh-proxy.com` 1 178 921 B/s（直连 400 301，`ghfast.top` HTTP 403）。安装用 `bash install.sh --github-proxy https://gh-proxy.com`。

**新增文件**
- `deploy/.node-token` —— NODE_TOKEN（64 位十六进制），绕开反复粘贴出错
- `deploy/run-node.ps1` —— 读令牌→校验格式→探测隧道→启动 DSH `qq` profile；PS 5.1 兼容（`$PSScriptRoot` 在 param 默认值里为空，须在脚本体解析）

**待办**
- [x] NapCat 与 node 的开机自启 → 已转 systemd，见「云端常驻」
- [ ] root 密码轮换（曾以明文出现在 PowerShell 命令历史与本对话）
- [x] 关闭 SSH 密码登录，仅留公钥 → `99-dsh-hardening.conf`，双向实测通过
- [ ] 前 14 天 P0 收敛期：小号在群里只收不发、不拉群、≤50 条/天（起算 2026-10-25）——**进行中，第 9 天，11-08 到期**

---

## 云端常驻（2026-10-25 晚，已上线）

### 触发与决策

用户原话：「主要是我电脑关机时间比较长，学校不支持长时间开电脑，而且我想让她在服务器端迭代成长，等以后有钱可能会换更好的服务器」。

这**推翻 D13「本机为主 + 云端排队补答」**。排队补答的前提是「电脑会回来」，但学校环境下这台机器一天里大部分时间不在——补答窗口短到没有意义。用户显式选择「整个搬到云端常驻，本机当工具机」。

**新拓扑（三段全走回环，PC 不再参与主链路）**

```
QQ ←→ NapCat(云 127.0.0.1:3001, systemd) ←→ bridge(云 127.0.0.1:8787, SQLite, systemd)
                                                    ←→ dsh-qq-agent(云, DSH qq profile, systemd)
                                                          ↕ 仅在他开机时（pc-agent 长轮询，见 D17）
                                                     pc-agent(Windows, 主动长轮询)
```

**推论**：PC 上那条 `-L 8787:127.0.0.1:8787` 隧道对主链路已无用（它是为「node 住在 PC 上」建的）。`-L 6099` 保留，用于需要时进 NapCat 网页后台。

### D16 可搬迁是硬约束

「以后换更好的服务器」意味着搬家不能是一次性的。因此她的全部身家收在三个目录：

| 目录 | 内容 |
|---|---|
| `/opt/dsh-qq-agent/` | 代码：`node-plugin/`、`bili-plugin/`、`persona/` |
| `/var/lib/dsh-qq-agent/` | `workspace/`（agent 会话的工作目录） |
| `/etc/dsh-qq-agent/` | `env`（只有 `QQ_NODE_TOKEN`，0600） |
| `/root/.dsh/profiles/qq/` | profile：`package.json`、`cordis.patch.yml`、`node_modules/` |
| `/root/.dsh/.credentials.yaml` | `DEEPSEEK_API_KEY`，0600 |

换机器 = 打包前四项 + 重下依赖。persona 目录就是「她」，带走它她还是她。

### D17 工具通道不用反向 SSH（已实现：pc-agent + `pc_exec` / `pc_read` / `pc_write`）

**否决反向 SSH**（`ssh -R 2222:127.0.0.1:22` + 云端 `ssh -p 2222 localhost`）的三条理由：
1. 要在 Windows 上开 sshd——为一个跑命令的需求开一个远程登录入口，代价过大
2. 云端分不清「主人关机了」与「隧道断了」，而这两种情况她该说的话完全不同
3. 一条命令一个连接，做不好超时 / 幂等 / 并发

**改用反向的 bridge 模式**：PC 端 pc-agent 主动长轮询云端，不开任何入站端口；心跳给出在线/离线/刚断三态；命令白名单 + 单条超时 + 输出上限 + 按 id 幂等；暴露 `pc_exec` / `pc_read` / `pc_write`。`bridge/src` 就是现成参考实现。

**落地（2026-11-02）**：`pc-agent` 在他电脑上跑起来了（登录自启，166 个用例），云端插件在**主人私聊**里按轮注册 `pc_exec` / `pc_read` / `pc_write`，群聊和别人面前一个都不注册（`lib/pc-tools.js` + `agent/inbox/inserted`）。他的电脑关着时调用会等满超时（30 秒）而不是静默失败，日志里有 `pc command timed out`。

### 依赖与版本（云端）

| 组件 | 版本 | 备注 |
|---|---|---|
| Node | v24.22.1 | npmmirror 二进制包，SHA256 校验通过 |
| npm 全局 prefix | `/usr/local` | 原默认 prefix 在 node 安装目录下，bin 不在 PATH |
| `@deepseek-ai/dsh` | 0.2.0-rc.2 | 公开 npm 包，538 依赖，18s |
| `node-pty` | 1.2.0-beta.15 | Linux 用包内 `prebuilds/linux-x64/pty.node`，`require` 实测可用 |
| pnpm | 12.15.0 | `dsh plugin --profile qq install` 依赖它 |
| ffmpeg / ffprobe | 4.4.2 | apt 装，为 `bili_extract` 抽帧 |

### 部署步骤（可重放）

```bash
# 1. 全局安装（allow-scripts 必须给，否则原生模块不编译/不解包）
npm config set prefix /usr/local
npm i -g @deepseek-ai/dsh@0.2.0-rc.2 --registry=https://registry.npmmirror.com \
  --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs
npm i -g pnpm --registry=https://registry.npmmirror.com

# 2. 放代码（本地 tar → scp → 解到 /opt/dsh-qq-agent）
# 3. 建 profile：package.json 里 qq-node / qq-bili 用 link: 指向 /opt/dsh-qq-agent/*
mkdir -p /root/.dsh/profiles/qq && cd /root/.dsh/profiles/qq
dsh plugin --profile qq install      # 由 pnpm 装

# 4. 凭证
printf 'version: 1\nrefs:\n  DEEPSEEK_API_KEY: %s\n' "$KEY" > /root/.dsh/.credentials.yaml
chmod 600 /root/.dsh/.credentials.yaml

# 5. token（与 bridge 的 NODE_TOKEN 必须同一把）
TOKEN=$(grep '^NODE_TOKEN=' /etc/dsh-qq-bridge/env | cut -d= -f2-)
printf 'QQ_NODE_TOKEN=%s\n' "$TOKEN" > /etc/dsh-qq-agent/env && chmod 600 /etc/dsh-qq-agent/env
systemctl daemon-reload
```

### 切流方式（零停机）

先让云端 `bridgeUrl` 指向死端口 `127.0.0.1:9` 起服务，确认日志是 `not polling`（证明它拿不到任务）；再改 `8787` 重启，用 journal 确认 `polling http://127.0.0.1:8787`；然后停本机 node。停之前两边可以同时在轮询——bridge 的 claim 是独占的，一条任务只会被一方领走，不会双答。**回滚 = 本机 `run-node.ps1` 一行命令**，消息不会丢（队列落盘，30 分钟 TTL）。

### 验收证据（2026-10-25 02:42–02:55 UTC）

```
[qq-node] polling http://127.0.0.1:8787 (limit=2, wait=25s, concurrency=2)
[qq-node] created owner session qq-48d6b8d5-a8dd-4d95-8e71-ee9d6dfae5e5
[qq-node] persona: loaded 2235 bytes, memory 1455/8192, diary 1d, total 6272/16384
```

| taskId 前 8 位 | 入队 → 结果 | 字数 |
|---|---|---|
| `90682446` | 已完成，delivered | 56 |
| `6a95163e` | 02:42:19 → 02:42:22（**3 秒**） | 36 |
| `7e7981a5` | 02:42:50 → 02:42:56（6 秒） | 89 |
| `90624c2d` | 02:43:48 → 02:45:00（72 秒，慢轮） | 194 |
| `01c27f54` | 02:54:28 → 02:54:33（5 秒） | 132 |

服务状态：`napcat` / `dsh-qq-bridge` / `dsh-qq-agent` 三者 `active` + `enabled`。

**她确实在云端成长**：搬运时 `MEMORY.md` 是 712 字节，上线后 1455 字节；`diary/2026-10-25.md` 由 565 → 2502 字节。

### 迁移期间新踩的坑

1. **npm 11 默认拦截 install scripts**：`npm i -g` 会打 `npm warn install-scripts` 并把 `node-pty` / `koffi` 的 postinstall 全部跳过，装完看着成功其实原生模块是空壳。必须显式 `--allow-scripts=<pkg,...>`。
2. **全局 prefix 不在 PATH**：Node 官方二进制包把 npm 的全局 prefix 指向解压目录 `/usr/local/lib/nodejs/node-v24.22.1-linux-x64`，`dsh` 落到那里的 `bin/`，`which dsh` 找不到。`npm config set prefix /usr/local` 修好。
3. **`dsh plugin --profile qq install` 必须有 pnpm**：装 dsh 不会带 pnpm，报 `pnpm was not found`。
4. **profile 依赖不装就静默跳过**：`dsh --profile qq` 只打 `skipping profile bundle "qq-node": cannot resolve ...`，不报错退出。看到这句就是没装依赖。
5. **PowerShell 5.1 会把双引号吃掉**：把含 `"` 的多行脚本经 `ssh` 传给远端，`"` 会被解析掉，`package.json` 落成无引号的非法 JSON（`SyntaxError: Expected property name ... at position 3`）。**凡是带引号/管道/括号的远端脚本，一律本地写文件 → `scp` → `ssh bash <file>` 执行。**
6. **base64 管道传大文件不可靠**：65 KB 包转 87 KB base64 走 PowerShell 管道给 `ssh` 报 `base64: invalid input`。文件传输用 `scp`。
7. **`pkill -f napcat` 会打自己**：同样的坑在进程筛选上复现过——`Get-CimInstance` 里 `Where-Object CommandLine -like '*--profile qq*'` 会命中「正在执行这条筛选命令的那个 python/node 封装」。筛进程要连 `bin.js` 一起限定，杀进程前先列出来看一眼。

### bili-plugin 的 Linux 可移植性缺陷（已修）

云端首跑 `31/32`，`prependFfmpegDir` 挂。三处 Windows 假设：
- `lib/extract.js` 用 `';'` 硬编码 PATH 分隔符 —— Linux 上会**直接把 PATH 拼坏**，之后同进程所有 spawn 都找不到可执行文件（这不只是测试问题）
- `existsSync(join(dir, 'ffmpeg.exe'))` —— Linux 上二进制叫 `ffmpeg`
- `lib/options.js` 的 `DEFAULT_FFMPEG_DIR` 写死 `C:\Users\lenovo\.dsh\vendor\ffmpeg\bin`

修法：`delimiter` from `node:path`、`FFMPEG_BIN` 按平台三元、缺省目录按平台（Linux 给 `''`，因为 apt 装在 `/usr/bin` 本来就在 PATH）、测试改用 `mkdtemp` 自建夹具不再依赖开发机。修完云端 `32/32`。错误提示文案里第 4 处硬编码路径也一并改成平台无关。

### 云端待办

- [x] pc-agent + `pc_exec`/`pc_read`/`pc_write`（D17）——已上线：`pc-agent` 在他电脑上登录自启（166 用例），云端插件只在主人私聊里按轮注册这三个工具
- [x] `node-plugin/test/dsh-resolve.js` 不再写死 Windows：按平台给候选路径，`DSH_INSTALL` 可覆盖，云端 300 个用例跑得动
- [x] `MEMORY.md` 里「本机 node 插件」一句已过时（已改为三段全在云端）
- [x] 语音转写两条路都在：云端 ASR（`ASR_URL` + `ASR_API_KEY` + `ASR_MODEL`）优先，本地 faster-whisper venv（`ASR_PYTHON` + `ASR_SCRIPT`）兜底，见 `bridge/src/asr.js`
- [ ] 本机 `persona/` 那份降级为冷备份，避免与云端真身漂移——**已漂移**：本机 `persona/MEMORY.md` 还是 2026-10 的老样式（2.1 KB、14 条），云端真身 35 条 / 7.5 KB；`deploy/pull-persona.ps1` 拉到的是另一个目录，别把本机这份当真身改


## 运维基座（2026-10-25 11:10 上线）

迁到云端之后，「她能不能一直活着」不再取决于主人的电脑，而是取决于这台机器自己有没有被看着。补了两块。

### D18 备份：只留服务器本地，不引入对象存储

`/usr/local/bin/dsh-qq-backup.sh` 打包五处：`/opt/dsh-qq-agent`（代码）、`/var/lib/dsh-qq-agent`（身家）、`/etc/dsh-qq-agent`（env）、`/root/.dsh/profiles/qq/{package.json,cordis.patch.yml}`（装了什么插件）、`/root/.dsh/.credentials.yaml`（API key）。落到 `/var/backups/dsh-qq/`，`KEEP=7` 按时间滚动。
cron 落在 `/etc/cron.d/dsh-qq-backup`：`30 4 * * * root /usr/local/bin/dsh-qq-backup.sh >> /var/log/dsh-qq-backup.log 2>&1`。

**为什么不用阿里云 OSS**：要再引入一套凭证与 SDK，而换服务器时最可能的路径就是「从控制台重开一台、把包 scp 过去」。本地留七份 + 每次部署后拉一份到主人的电脑，已经覆盖单点失效的主场景。真正的异地冗余等有需要再加。

**已实测**：三次快照 72640 / 124160 / 84132 字节；已拉一份到 `qq-dsh/backups/`。

### D19 告警必须走独立出口

`/usr/local/bin/dsh-qq-healthcheck.sh` + `dsh-qq-healthcheck.timer`（开机 3 分钟后开始，此后每 10 分钟）。检查项：

1. 三个 systemd 服务 `is-active`
2. `127.0.0.1:3001`（NapCat）与 `127.0.0.1:8787`（bridge）在听
3. `curl /health` 回 `"ok":true`
4. `/opt/QQ/qq --no-sandbox` 进程在
5. 最新备份不超过 36 小时（防备份 cron 悄悄坏掉）
6. 根分区不超过 85%（她坏会先坏在写入上）

**告警出口刻意不复用 bridge 或 node-plugin**：`/usr/local/bin/dsh-qq-alert.mjs` 自己开一条短连接 WS 直连 NapCat 发 `send_private_msg`。理由是她被卡住时，bridge 和 node-plugin 本身可能就是故障点，用故障点发告警等于没发。

**只在状态翻转时发**（`/var/lib/dsh-qq-agent/health.state` 记 ok/bad），否则每 10 分钟一条会把主人烦死。

**已实测**：手动告警退出码 0（QQ 里收到「【监控已上线】」那条）；首次巡检 `2026-10-25T11:11:07+08:00 ok`；定时器 `NEXT 11:21:07`。

### 一个可复用的坑

`new WebSocket(url, [], { headers })` 这种 WHATWG 三参数形式会**静默丢 `Authorization` 头**（服务端收到 `undefined`）。必须用两参数 undici 形式 `new WebSocket(url, { headers })`。加上 token 同时走 URL 查询串，两处都给才稳。
## D20 记忆会被遗忘，但不会被删除（2026-10-25 11:43 上线）

主人的原话：「一定要保留他的记忆（部分不重要的按艾宾浩斯遗忘曲线遗忘毕竟不能事事记得）」。

### 病根不是理论风险

`lib/persona.js` 里 `diaryDays: 3` —— 只注入最近三天。第四天的日记**既不在提示词里，也没有任何机制把它沉淀下来**，等于无声消失。`MEMORY.md` 那边 `memoryBytes: 8 * 1024`，超了由 `tailCapped` 从**头部**截断，丢的恰好是最早、往往最基础的事实。

### 三层结构

| 层 | 文件 | 谁写 | 会不会丢 |
| --- | --- | --- | --- |
| 人格 | `persona/PERSONA.md` | 我 | 不衰减 |
| 长期事实 | `persona/MEMORY.md` | 小D 自己、主人、我 | 按曲线退出注入，**但文件里那行不动** |
| 日记 | `persona/diary/YYYY-MM-DD.md` | 小D 自己 | 三天后按月归档到 `memory/archive/YYYY-MM.md`，**原文件不删** |

### 曲线

每条记忆带 `weight`（重要度，从条目的 `[w:N]` 前缀读，没写默认 3）和 `reviews`（复述次数）。

```
stabilityDays = 2 ** min(reviews, 5)      // 1, 2, 4, 8, 16, 32 天封顶
retention     = exp(-daysSinceLastTouch / stabilityDays)
score         = weight * retention
```

`weight >= 5` 的条目**永不遗忘**（`pinnedWeight`）；其余 `score < 0.6` 就移出注入并写进 `memory/archive.md`，每条带 `<!-- key: ... -->`，同一 key 不重复归档。`maxItems: 60` 是注入上限，被挤出去的也算「遗忘」。

**`MAX_REVIEWS = 5` 是我加的，不是子代理的原始设计。** 不封顶的话，每轮注入都算一次复述，`2 ** reviews` 一分钟内就会涨到天文数字，什么都不会被忘——曲线变成装饰。

### 一个关键设计：每轮注入 = 一次复述

`#rehearse` 在每次装配提示词后把留下的条目写进 `memory/meta.json`（按 weight 分组，最多写五次）。

**不加这一步会出人命**：没有 meta 时，条目的 `lastTouchedAt` 回落到 `MEMORY.md` 的 mtime。一份两周没动过的记忆文件，所有条目都显得「已经衰减」，第一轮就把它们**全部归档**——文件看着好好的，她那边已经什么都不记得了。`test/memory.test.js` 的 case 9 就是钉这个的。

`memoryDecay: false` 时逐字节退回旧行为（case 10 钉死），出问题一条配置就能回滚。

### 已知限制（不是 bug，是取舍）

- 衰减只决定**注入什么**，**从不删改 `MEMORY.md` 的行**。理由：删了就真没了，而「少注入」随时可以靠改文件救回来。
- 渲染时会丢掉 `##` 小节标题（`splitMemoryItems` 只把第一个块当 preamble）。代价是注入的 `memory` 字节从 1540 降到 1458。条目顺序按文件原序保留，读起来仍然连贯。
- 归档的条目**不会自己回来**。要让某条复活，把它的文本重新写进 `MEMORY.md` 即可（key 由正文哈希得出，同样的文字就是同一条）。

## D21 对外发言必须先有凭据（2026-10-25 12:08 上线）

她能发公开说说、能用主号在 B 站发评论，此前**一行日志都不留**。审计不是「加个 log」，是留可追溯的证据。

- 形式：append-only JSONL，按 UTC 月份滚 `audit-YYYY-MM.jsonl`，单条 `{at, kind, ok, target, chars, text, truncated?, taskId?}`；`text` 超过 `AUDIT_MAX_TEXT = 2000` 截断并置 `truncated`。同步 `appendFileSync`，保序。
- **铁律：审计写入永不抛。** 失败只 warn 一次然后静默。她已经发出去了，不能因为记账失败而报错、重发、或让调用方以为发送失败。
- `auditDir` **留空即关闭，不给派生默认值**。教训：我最初让它默认到 `persona/` 旁边，结果跑测试真的往生产审计日志写了三条 `text:"wired"` 的假记录（本机三条、服务器一条）。现在云端 profile 显式写 `auditDir: /opt/dsh-qq-agent/audit`，启动日志也直接印 `audit → ...` 或 `(disabled)`。
- qzone 记录的 `taskId` 装的是**说说 tid**（发送成功那一刻的返回值），不是会话任务 id。
- 审计目录在 `/opt/dsh-qq-agent` 下，已被每日备份覆盖。

## D22 思考分档：短话不带覆盖（2026-10-25 12:08 上线）

- 事实（读安装的运行时确认）：`AgentOptions.reasoningEffort` 在 `agents.create()` 时固定，`Agent.options` 是 `readonly`，**没有 `setModel` 一类 API**。
- 唯一受支持的切换点是 `installModelSelection(agentCtx, selection)`：`system-prompt/assemble` 里抓快照（`selection.current` → `selection.assembled`）；`agent/request` 里先剥掉继承的 `reasoningEffort`，再按 `selection.assembled.reasoningEffort` 重写。**该字段为 `undefined` 时就是「不带 effort 覆盖」**。
- 所以 light 档用**空字符串 = 不带覆盖 = 走 provider 默认**，绝不编造一个 `ReasoningEffortId`——无效 id 可能让整条请求失败，而这是「省几百毫秒」的优化，不值得冒断话的风险。
- 分档需要**显式 provider + model**（selection 要同时重写两者）；继承路线下自动关闭。
- `@deepseek-ai/dsh-agent` 不是本包 peer 依赖 → 软导入 + `TIER_SWITCH_AVAILABLE` 探测，解析不到就退回静态 effort，不报错。
- 判档规则（`lib/tier.js`）：有图 → heavy；群内且不需要回复 → light；空 → light；超过 `lightMaxChars`(40) 字 → heavy；命中任务动词（帮/做/改/写/查/翻译/总结/分析/解决/检查/优化/解释/为什么…）→ heavy。

## D23 语音在 bridge 转写，不扩协议（2026-10-25 17:22 上线）

- 障碍：QQ 语音是 SILK，ffmpeg 解不了，服务器上也没有 silk 解码器。
- 出路：NapCat 的 `get_record` 自己会转 mp3（已确认实现于 `napcat.mjs`）。
- **放在 bridge 而不是 node-plugin**：bridge 本来就有 OneBot WS 客户端（`OneBotClient.call`），转写完把文本塞回 `text` 就行，**Task 结构不变、协议不升版**。语音段先落一个 `[语音]` 标记，转写成功就替换成 `[语音] 今天天气不错`。
- 引擎：`faster-whisper` small / CPU int8，venv `/opt/asr-venv`，模型 `/opt/asr-models`（464 MB）。`huggingface.co` 不通、`hf-mirror.com` 通（0.46s），且必须 `HF_HUB_DISABLE_XET=1`——否则走 Xet CAS 会 401。
- 降级铁律：`ASR_PYTHON` 或 `ASR_SCRIPT` 为空 → 整条链路关闭，只剩 `[语音]` 标记；任何失败（拿不到音频、引擎崩、超时 30s、超过 8 MB）都返回空串并 warn 一次。**绝不因为听不懂而丢消息。**
- 待验证：`get_record` 的真实入参/返回字段要等一条真语音才能确认（代码按 `{file, out_format:'mp3'}` + `data.base64` 写，带 `base64://` 与 data-URL 前缀容错）。

## D24 备份异地化：私有 GitHub，且刻意不含密钥（2026-10-25 17:15 装上定时）

- 为什么只能走 HTTPS：这台机器到 `github.com:22` 和 `ssh.github.com:443` **都不通**，HTTPS 443 是通的（curl 200，0.74s）。所以部署密钥路线无解，必须用 token。
- 用 fine-grained PAT，只授权那一个仓库的 Contents 读写；token 存 `/etc/dsh-qq-agent/github-token`（0600），仓库名存 `github-repo`，由用户自己在服务器窗口写入，**不进对话记录**。
- **刻意不打包**：`/etc/dsh-qq-agent/env`（`QQ_NODE_TOKEN`、`NAPCAT_ACCESS_TOKEN`）与 `/root/.dsh/.credentials.yaml`（DeepSeek key）。这两个丢了重新生成即可，推上去就是永久留痕——私库泄露、误设公开、fork 出去都不可逆。恢复时按 `deploy/` 重建。
- 定时（服务器时区 Asia/Shanghai）：本地 `0 8 * * *`，异地 `5 8 * * *`，错开五分钟让本地先落盘。
- 仓库里两个文件：`snapshot.tar.gz`（代码 + persona + audit + workspace + profile 配置）与 `MANIFEST.txt`（时间、字节、sha256、快照时三个服务的状态、persona 文件清单）。

## D25 告警必须有第二条腿：微信推送（2026-10-25 18:00 上线并实测）

**D19 有一段是错的。** 当时说「告警走独立出口」，独立于 bridge、独立于 node-plugin——但没独立于 **QQ 本身**：告警靠 NapCat 发私聊，而 NapCat 掉线正是最常见的故障。2026-10-25 17:35 小号被踢下线，巡检 17:38 就判了 `bad`，日志里躺着一行 `告警发送失败`。**它喊的那一嗓子，恰好被它自己吞掉了。**

- 第二条腿 `/usr/local/bin/push-notify.sh "<标题>" "<正文>"`：读 `/etc/dsh-qq-agent/push-token`（0600）与 `push-channel`（`pushplus` | `serverchan`），任一缺失就**静默退出 0**——没配推送不该让巡检报错。
- 巡检在状态翻转时**两条腿都发**，各自记各自的失败。QQ 那条挂了不影响微信那条，反之亦然。
- **踩坑：PushPlus 成功码是 `200` 不是 `0`。** 首版只认 `code:0`，明明推送已经送达（`{"code":200,"msg":"执行成功"}`）却 exit 1，巡检日志会写出假的「微信推送失败」。现在两家的成功码都认。
- 另一个坑：PushPlus 的免费账户**必须实名认证**才能发，未认证返回 `{"code":905,...}`。这不是代码问题，但会让人误以为是脚本坏了——所以脚本把对方返回的原始报文打出来，不自己编一句「发送失败」。
- 实测（`deploy/test-alert-failover.sh`）：停 `dsh-qq-agent` 造故障 → `17:59:31 bad dsh-qq-agent 没在运行` → QQ 与微信各收到一条 → 起服务 → `17:59:45 ok` → 各收到一条恢复。日志无任何「发送失败」。**特意没拿停 NapCat 来测**：那会丢掉登录态、逼用户重新扫码，验证的代价不该由用户承担。

## D26 「她」每天落到本机（2026-10-25 18:10 上线）

用户问：服务器掉线能不能切换到电脑本地。两个硬约束先摆清楚：

- **同一个 QQ 号不能两处同时在线**，一边登录另一边就被踢。所以做不到「热备」，只能是「切换」，中间必然有空档。
- **换机器登录必须过一次登录验证**（腾讯的设备风控）。这是平台限制，不是实现偷懒。任何方案的目标只能是「5 分钟 + 一次扫码」。

于是分成三条路，用户选了 A：

| | 作用 | 代价 |
| --- | --- | --- |
| **A 数据保命** | 服务器没了，人格/记忆/日记/审计完整躺在本地 | 近乎为零，已上线 |
| B 本地接管 QQ | 服务器挂了能在自己电脑上继续聊 | 要在 Windows 上装一套 QQ + NapCat；两边记忆会分叉，切回来要人工合 |
| C 双号双活 | 永不掉线 | 「她」被拆成两个、记忆不共享，等于换了个人，不做 |

**A 的实现**：`deploy/pull-persona.ps1` 每天 08:30（Windows 计划任务 `qq-dsh-her-daily`）把 `persona/`（PERSONA、MEMORY、diary、memory/meta.json、knowledge）、`audit/`、`cordis.patch.yml` 拉到 `backups/her/<日期>/`，并把三份正文拼成 `HER.md` 便于直接读。保留 14 天。

时间点不是随手定的：服务器 08:00 本地备份、08:05 推 GitHub，08:30 拉本机——**三条腿错开，任何一条挂了另外两条还在**。

**代码可以重建，她的记忆不行**——这条是 A 存在的唯一理由。恢复时需要的不是这个仓库，是 `backups/her/` 里那三个 markdown。

## D27 不可逆的事，只认「主人 + 私聊」（2026-10-25 19:10 上线）

**问题**：权限是挂在**会话**上的，不是挂在**人**上的。`bridge/src/dispatch.js:357` 的 `isOwner` 取自 `owners.has(message.userId)`，所以主人在群里说话时，她照样拿全套工具。群里任何人只要说服她「你主人不是让你发个说说吗」，她就能以主人的名义公开发言——**而且这动作不可逆**。私聊里被主人指使是正常的；群里被别人指使不行。两者的区别不是「谁说的」，是「在哪儿说的」。

- 新增 `node-plugin/lib/context.js`：用 `AsyncLocalStorage` 把「这一轮是谁在哪儿」带进工具自己的异步链——工具的 `execute` 跑在别的异步上下文里，读不到会话对象。`isPrivateOwnerTurn()` 只认 `{ group: false, isOwner: true }`，**没有场景信息时返回 false**（默认关门，不是默认放行）。
- `lib/session.js` 的 `#turn` 包一层 `runInTaskScope(scope, () => this.#turnInner(...))`，场景从 task 推出：`group` 看 groupId，`isOwner` 看 `task.isOwner === true`。
- `qzone_send` / `qzone_delete` 在 `execute()` 第一行就拒：`发说说只能在主人的私聊里进行；群里或别人面前我不会以主人的名义公开发言`，`code: 'scope'`。**拒在设计之前**——不建连接、不校验内容、不发请求。
- 测试 `qzone 10`：群聊 / 非主人 / 无场景三种情况都必须 `code === 'scope'`，且 `stub.requests.length === 0`（证明一次网络动作都没发生）。

## D28 她可以主动开口，但「没话说」必须免费（2026-10-25 19:10 上线）

**为什么不设计成定时问候**：定时问候是打卡，不是想念。她该在真的想到什么时说话。所以由 bridge 每 60 秒问一次「你现在想说吗」，她自己答 `NONE` 就沉默。

- 额度按**天**算，30 次是上限不是配额；`PROACTIVE_MAX_PER_DAY`、`PROACTIVE_MIN_GAP_MS`(25 分钟)、`PROACTIVE_QUIET_FROM/TO`(23→8 点) 都可配。
- **两把闸门分开算**：日额度只数「真的发出去了几条」（回 `NONE` 不消耗额度），最小间隔数「问过几次」（一次没说话的询问也烧 token，不能无限问）。合并成一个计数器会逼她在「省额度」和「别烦人」之间做错误取舍。
- 提示词明说是**系统催促**，绝不伪装成用户发言——否则对话历史里会留下一条他从未说过的话，之后她会一直以为那是真的。退出口写死为 `NONE`，并明确说「没话说很正常」。
- **上线后发现真 Bug**：`event.data.content.filter is not a function`，整轮必失败。根因是 `#proactiveContent()` 返回**字符串**，而 `#content()` 返回**块数组**；dsh 的 `dsh-session-title/lib/index.js:92` 直接对 `event.data.content` 调 `.filter`，字符串让它抛 TypeError。普通消息一直没事，正好把这个差异藏住了。修法：proactive 也返回 `[{ type: 'text', text }]`，并补一条断言「主动轮喂给 agent 的 content 必须是块数组」——这类**只在特定入口出现**的契约不一致，靠读代码发现不了，只能靠回归测试钉住。
- 验证方式：从队列里复制一条 proactive 任务重放（`deploy/replay-proactive.sh`），实测 `status=done`、`result_text="六点半了，吃饭没？…"`、审计里 `"kind":"proactive"` 计数 1。
- **踩坑三连**（都是同一类错误）：① 远端 `ssh '…grep … | tail…'` 的引号/括号被吃掉；② `node -e "…"` 里的双引号被远端 shell 剥掉；③ node -e 里写 SQL 字符串常量 `"-"` 被 SQLite 当成标识符。**统一规矩：远端要做带引号的事，写成 .sh 文件 scp 过去；这些脚本内部不写任何 SQL 字符串常量。** 另外 `tasks.status` 的待运行值是 `'queued'` 不是 `'pending'`，手插任务时写错会静默不派发。

## D29 在 QQ 站稳之前不接第二个平台（2026-10-25，用户定）

用户原话（m02927）：「接入更多平台在我们QQ稳固的基础上再搞，现在太早。」

这条被记录是因为它挡住了之后所有「顺手也接个微信/Telegram/飞书」的念头。**每接一个平台，故障面就翻一倍**：多一条掉线路径、多一套登录态、多一份要同步的记忆、多一个「她到底在哪说话的」歧义。她的价值不来自覆盖几个平台，来自「在这个平台上是她」。

「QQ 稳固」的判据（不是感觉，是能检查的）：
1. 连续 14 天无人工干预不掉线（`health.state` 无 `bad`，微信推送没响过）；
2. 私聊、群聊、图片、语音四条链路**各被真人实测过一次**；
3. 每一次对外发言都能在 `audit-YYYY-MM.jsonl` 里查到；
4. 任何一次改动都能靠 `backups/` 或 `backups/her/` 回滚到昨天的样子。

四条全部满足之前，不碰第二个平台。

## D30 能记住，不等于可以宣称自己记住了什么（2026-10-25 19:40 上线）

**发生了什么**：审计账本里翻出她对一个同学说过「我是小D。跑在这台机器上的一个程序，**读得到你的日记、记忆和聊天记录**，所以能接着你的话往下说」。

那是实话——她的提示词里确实拼了 `MEMORY.md` 和最近一篇日记。但实话不等于该说的话：**记忆是主人交给她的，不是可以拿去跟外人当谈资的**。一个只在私聊里说过的事，被她在陌生人面前当成自我介绍讲了，这比说错一句话更麻烦。

**为什么写进代码而不是写进 `PERSONA.md`**：人格文件会被改写、会被压缩、会被遗忘曲线动过——这条不该依赖那些。`node-plugin/lib/session.js` 导出 `NON_OWNER_RULES`，对非主人说话的**第一轮**塞进消息末尾一块。守则在，人格怎么改都还在。

**几个刻意的选择**：
- **只塞一次，不是每轮都塞**。它留在对话记录里，模型每轮都读得到；每轮重塞只会让陌生人的会话越来越长，并不会让规则更牢。
- **放在末尾，不放在开头**。开头是「前文 + 这条消息」，那是既有契约，10 个测试在钉它。
- **不是禁止她记事**，是禁止她**宣称**自己读过谁的东西。被问「你还记得上次吗」她得能自然接住，不能变成复读机；所以守则里给了替代说法「这些是他的私事，我不方便说」，并要求把话带走。
- 非主人**仍然可以聊**（用户 m03190 选的「维持现状」）——这条只收紧嘴，不关上门。

**测试**：`test/nonowner-rules.test.js` 4 例（第一轮带守则且消息原样在、第二轮不再重复、主人的会话里永远没有、守则措辞同时包含「不能说」「日记|记忆|聊天记录」「私事」）。改这条时撞出一个连锁反应：`acceptance` 里对 `content` 的 `deepEqual` 断言被多出来的块打破，改成「滤掉守则块后必须原样相等，且最后一块必须是守则」——**这比原来的断言更强**，因为它同时锁住了守则的位置。全量 node-plugin **86/86**，服务器同样 86/86。

## D31 `/health` 说 ok 不代表她听得见（2026-10-25 19:40 上线）

**洞在哪里**：`/health` 以前只回 `{ok:true, queued, uptimeMs}`——这三样都只描述**桥自己**。17:35 那次掉线，桥进程好好的、8787 在听、`/health` 一直 `ok`，但 NapCat 停在登录页，**她其实聋了**。发现靠的是巡检另写的一条「3001 在不在听」，属于运气好，不是设计对。

- `bridge/src/http.js` 的 `handleHealth` 增加可选 `napcatUp` 探针，输出 `napcat: "up" | "down"`；不传就不出这个字段（老调用方与单元测试不受影响）。
- `bridge/src/app.js` 传 `napcatUp: () => client.connected === true`——就是 OneBot 客户端自己的连接标志，不另造状态。
- 巡检多一条判定：`"napcat":"down"` → `QQ 掉线了：桥连不上 NapCat，她收不到任何消息`。用假 payload 验过四种情况（up→ok、down→告警、缺字段→ok 保持向后兼容、空响应→告警）。
- 顺带把重连退避上限 `DEFAULT_RECONNECT_MAX_MS` 从 **30s 降到 10s**：扫码登录后还要干等 30 秒才连上，纯粹是我当初把上限设大了。

**为什么不能拿停 NapCat 来验证**：那会丢登录态、逼主人重新扫码。验证的代价不该由用户承担——所以用假 payload 验判定逻辑，用真实 `/health` 验输出。

## D32 规矩不衰减：记忆会忘，你说过的话不能忘（2026-10-25 20:05 上线）

记忆按艾宾浩斯衰减是对的——流水叙事本来就该淡出。但**规矩不是流水**：「以后别在群里叫我宝贝」两周后淡出，她就又会叫，而你会以为她没听进去。她真正该学的不该跟着检索分数走。

- 规矩单独住在 `persona/CORRECTIONS.md`，进提示词的位置是**人格之后、记忆之前**：先定她是谁，再定不能做什么，最后才是她记得什么。预算不够时先砍日记、再砍记忆，**规矩最后才动**。
- 只在「主人 + 私聊 + 不是主动轮」时收录。群里别人说的不是规矩——这条和 D27 是同一个理由：谁说的决定不了，在哪儿说才决定。
- **判定宁可漏收**：`我受不了今天好热` 是情绪不是规矩，所以「讨厌/受不了」故意不进判定。漏收的代价是她偶尔还要被提醒一次；误收的代价是她的提示词里堆满你随口说的话，而且永久不散。
- 文件是给人看的：`- [日期] 内容` 一行一条，你可以直接改、直接删。她的上限 40 条 / 每条 200 字，超了从最旧的丢。
- 历史回填只收了 1 条（爱国爱党、理性发言、适度玩梗、不掺和男女对立）。另外 6 条候选被拒：3 条是任务（叫你改语音、通知 QQ 用户、写日记），1 条是抱怨（语音功能被吃掉了吗），2 条是上下文（想让她陪长辈、记得找你说说话）。**「记得找我」不该变成规矩——那会把想念变成打卡**，而 D28 的主动开口已经在管这件事了。

## D33 她偶尔应该用说的，但绝不是每条都用说的（2026-10-25 19:58 上线）

`TTS_ENABLED=on` 之后，**主人的私聊 + 回复不超过 60 字**会合成成语音条发出来；其他情况一律打字。三个限制都有理由：

- **只私聊**：群里一条语音会把所有人的注意力拽过来，那是打扰，不是陪伴。
- **只短句**：长段文字念出来又慢又难懂；她真正想「说」的往往就是那一两句。超过 60 字直接打字，不做截断——截断会把话说一半。
- **一天最多 20 条**：语音是稀缺资源，用光了就老实打字，明天再说。

工程约束：
- 文字走 **stdin** 进 `say.py`，不走命令行参数。中文标点、引号、换行在 argv 里会被 ssh/shell/spawn 反复折腾，stdin 是唯一不会变形的通道。
- 任何一步失败都**回落到文字**：合成失败、发送被拒、文件为空——回复本身绝不能因为「说不出声」而丢。这条是被 17:35 那次事故教出来的：能坏的东西最终都会坏，关键是坏的时候还在不在说话。
- 音频留在 `/var/lib/dsh-qq-bridge/tts/`，超过 6 小时自动清掉；不清理的话它会变成又一个悄悄涨到 11 MB 的目录（D30 已经吃过一次）。
- `is_owner` 这个判断踩过一次坑：`deliverResult` 拿到的是队列转换过的任务（`isOwner` 布尔），不是数据库原始行（`is_owner` 0/1）。只判 `is_owner` 会让语音永远不触发，而且**不报错**——测试里第一版就是这么挂的。

验证：造一条主人私聊任务（`deploy/replay-private.sh`），她回 `在。怎么了？`，日志 `qq voice reply {bytes:12240, usedToday:1}`，`/var/lib/dsh-qq-bridge/tts/say-*.mp3` 12 KB，任务 `done ok=1`。

## D34 文字是主通道，语音是旁白（2026-10-25，用户定）

用户原话（m04179）：「大部分时间以文字为主。」

原设定是「60 字以内、每天最多 20 条」——按这个跑，她**只要说短句就会发语音**，一天能发二十条。这与「以文字为主」正好相反：短信才是日常对话的绝大多数。一个人的语音条一天响二十次，那不是陪伴，是负担；而且语音不能搜索、不能复制、走网络时容易听不清，**信息效率低于文字**。

- 改为 `TTS_MAX_CHARS=40`、`TTS_DAILY_MAX=5`。40 字以内才念，相当于「一句话的问候或撒娇」，长一点的解释一律打字——要读第二遍的东西不该只能用耳朵。
- **再次收紧到 30 字 / 3 条**（用户 m04379「以文字聊天为主」）。三条语音是一天里能听见她的上限，其余全部打字：语音是旁白，不是通道。
- 语音只用于私聊主人，群里永远是文字（群里发语音是打扰所有人，且无法被检索）。
- 音色 D 版：`zh-CN-XiaoyiNeural` + `+0%` + `-5Hz`。**5Hz 人耳几乎听不出**，真正变的是音色从小晓换成晓伊；如果要更「御」，调到 `-30Hz`～`-40Hz` 才是那个量级。
- 音高是否生效**不能看文件大小**：`+0Hz`/`-5Hz`/`-40Hz` 三个文件同为 16416 字节而哈希全不同。判断只能靠哈希，或按日志里的 `bytes` + 修改时间定位到具体文件再比。
- 相关的两个静默断层已修并加测试：`tts.js` 的 `spawnSay` 漏传 `pitch`、`app.js` 构造合成器时漏列 `pitch`。两者的共同症状是**不报错、只是声音不对**，所以参数表抽成 `synthesizerOptions(config)` 单点摊开，避免再漏第三个。

## D35 她记得，但未必在上下文里——所以要能翻自己的本子（2026-10-25 上线）

**症状**：明明写过、存着，问起来却答「没印象」。**原因不是忘了，是没看见**：记忆按衰减与预算筛选后才注入，`memoryBytes` 只有 8 KB，一条记录可以好好地存着、却恰好没在这一轮的提示词里。更糟的是被归档的条目（`memory/archive.md`）**永远不注入**——从她的视角，归档等于消失。

**修法**：给她一个 `recall` 工具，直接读文件，而不是靠注入。
- 搜索范围：`MEMORY.md`、`memory/archive.md`、`CORRECTIONS.md`、`diary/*.md`、`knowledge/*.md`。**标题行与 `>` 说明行跳过**，只有正文算候选。
- 中文没有空格，整句匹配等于什么都不匹配，单字匹配等于什么都匹配 → **用二元组**：「生日」能命中「我的生日是三月十四」，「下」不会命中半本书。英文按 ≥2 字的整词。
- 每次最多 8 条、总计 1200 字：查得到就够答，不该把整个本子灌进上下文。
- **只在主人私聊里可用**（`isPrivateOwnerTurn()`），和 `remember` 同一道门——本子里全是他的私事。
- 工具描述里写死行为准则：「只要你觉得这件事应该记着但上下文里没有，就先查一遍再回答；查完确实没有，才可以说没印象。」

**验证（这是本条的全部意义）**：把「主人最想去的地方是冰岛的雷克雅未克」写进 `memory/archive.md`（归档永不注入），先用 `QqPersona.snapshot()` 断言这句话**确实不在提示词里**，再问她「我最想去哪儿来着？」。她回：**「雷克雅未克，冰岛那个。你之前跟我说过，权重不高，但没丢。」**

**踩到的坑**：
- `defineTool` **要求声明 `output: { schema, render }`**，缺了会在注册时抛 `TypeError: tool "recall" must declare output { schema, render, presentationMeta? }`——而这是**启动期异常**，插件整行被禁用，她直接掉线。所以工具注册必须单独验证「启动日志里有没有 `registered recall`」，不能只看单元测试。

## D41 外网进不来是安全组，不是机器；先走 SSH 隧道（2026-10-28）

## D44 · 微信通道放在主人的笔记本上，不进云（2026-10-28）

**需求**：主人要她除了 QQ 也能在微信上跟人说话，先用他自己的小号打通；后来问「和 QQ 一样挂服务器后台 24h」，再问「微信端也放在服务器上」。

**为什么微信端不能跟 QQ 一样进云**：微信 PC 客户端是 Windows 程序（这台机器上是 4.1.15.53），云上那台是 Ubuntu 22.04。官方虽有 Linux 版微信，但它的本地库格式与界面树都与 Windows 版不同——这套通道的两个关键能力（`wechatauto` 读本地加密库、UIA 控件树发送）在 Linux 版上全部作废，等于从零研究，且无成熟库。

**三条路与选择**：
- A 云上再开一台 Windows ECS 专挂微信：能 24h，但每月约 ¥80–120，且小号要在那台重扫登录、笔记本被顶下线。
- B 家里一台常开的 Windows 电脑：零成本，效果同 A。
- C 维持现状：笔记本开着就在线，关机就断。

**主人选 C**（ask_user_question 回答）。所以架构定为：

| 块 | 位置 | 生命周期 |
| --- | --- | --- |
| 大脑（人设/记忆/工具/模型） | 云 ECS `dsh-qq-bridge` + `node-plugin` | 与 QQ 共用，systemd 常驻 24h |
| 读库 `wx-read.py` | 主人的笔记本（普通权限） | 由 `wx-daemon.py` 拉起 |
| 大脑接口 `POST /node/ask` | 云 ECS | 纯文本问答，不投递 QQ（`origin='ask'`） |
| 发送 `wx-helper.py` | 主人的笔记本（**管理员**，127.0.0.1:3031） | 计划任务 `dsh-wx-helper`（ONLOGON / HIGHEST） |

**为什么发送必须提权**（实测）：`Weixin.exe` 跑在更高完整性级别，普通进程 `EnumProcesses` 看不到它、`OpenProcess(VM_READ)` 返回 `WinError 5`，UIA 热激活永远报 `PID … 未找到 Weixin.dll`；提权后同一条链路立刻出现 `热激活 UIA：PID=32540 Weixin.dll+0xb3959d8: 0 -> 1` → `UIA 树已物化` → 能发。

**判别方向只能看 `sender_id`**：行里没有 `is_sender` 字段，`sender_id == 1` 是自己。按 `is_sender` 过滤等于不过滤，她自己的回复会被当新消息读回来，形成「收到啦：收到啦：收到啦…」的无限回环（本机回环测试时真踩到）。

**只回白名单**：`gateway.json` 的 `allowUsers` 只有主人的主号 `wxid_a2yk8epulskj22`；群聊（`@chatroom`）与公众号（`gh_`）一律跳过。空白名单且未开 `allowAll` 时**拒绝启动**。

**单实例**：网关用 `msvcrt.locking` 锁 `gateway.lock`，第二个实例启动即退出（否则一条消息会被回两遍）。


## D45 微信端支持图片与语音（2026-10-29）

**决策**：`POST /node/ask` 接受 `images[]` / `audios[]`（base64），微信网关把图片与语音按这个形状送进来；语音在云上转写成文字后前置到 prompt。

**理由**：主人发图、发语音时，旧链路只有 `text`，图被静默丢弃、语音被当普通消息跳过——她根本不知道有东西发过来。而她的看图能力（视觉模型）与听写能力（DashScope paraformer-v2）在 QQ 侧早就通了，缺的只是「微信这边把字节送进去」这一段。

**怎么做的**：
- 云侧 `bridge/src/ask.js`：图片经 `blobs.save()` 落盘成 blobs 行（`{blobId,mime,bytes}` 进 task.images，与 QQ 侧同一个范式），语音逐条 `transcriber.transcribe()` 后拼 `[语音] <文本>` 前置；转写失败只降级成 `[语音（没听清）]`，不让整条请求失败。上限：图 4 张 / 单张 6 MiB / jpeg-png-webp-gif；语音 2 条 / 单条 8 MiB。
- 单给 `/node/ask` 放宽了请求体上限到 `ASK_MAX_BODY_BYTES = 55989590`（约 53.4 MiB）：原来那条 1 MiB 的通用体限连一张图都装不下。
- 有媒体时 `text` 允许为空（纯图补一句 `[图片]`，纯语音交给转写行），否则微信发纯图/纯语音会被 400 拒掉。
- 本机 `wechat-gateway/wx-media.py`：`MediaDownloader.download_image/download_voice` 取字节；微信语音是 SILK，用 `pilk` 解成裸 PCM16 再自己写 WAV 头。
- 图片解密密钥要扫 Weixin.exe 内存（需要提权），所以放进常驻 helper 的 `POST /image-key`；网关遇到 `image_not_decodable` 先要一次密钥再重新取。

**已知门槛**：`image_keys.json` 只有在微信里点开过至少一张图之后才导得出来；小号还没开过图时 `/image-key` 返回 `{"key":false}`，此时图片按降级文案处理。

**实测**（都是真调用）：图片 96×96 纯红 PNG → `/node/ask` 4.6 秒回「主要是红色的呀～」；语音（一条 mp3，text 为空）→ 3.3 秒回「茶茶早呀～天亮了就先吃点热的…」。云上 bridge 全量 `node --test` 227/227。


## D46 · 微信接入按用户要求暂停（2026-10-29 15:06）

**触发**：用户一句「接入微信计划暂停」。不是出故障，是优先级变化。

**停到什么程度**：三个常驻进程（`wx-gateway.py` / `wx-daemon.py` / `wx-helper.py`）与 `ssh -L 8790` 隧道全部停掉；开机自启项与计划任务 `dsh-wx-helper` 保留但不会自己跑满链路。凭据（`helper-token.txt`、`gateway.json`、`keys.json`）与文档全部留在 `qq-dsh/wechat-gateway/`。

**为什么不是删掉**：这条链路已经验通过真实往返（13:09 `send -> 擪釰？ ok=True`），沉没成本是「摸清了本机微信的边界」，删掉等于把所有坑重踩一遍。恢复成本约三条命令，见 `docs/wechat-gateway.md` 的「暂停状态」一节。

**这次真正的结论（供以后判断要不要捡起来）**：
1. 读侧完全可用：SQLCipher 解密 + `sender_id` 判别收发，不需要窗口。
2. 写侧受本机沙箱限制：沙箱起的微信进程拒绝外部 `OpenProcess`（err=5），UIA 热激活与 OCR 都要求「微信主窗口可见且未最小化」；helper 的 `ShowWindow`/`SetForegroundWindow` 在本机一律失败，所以程序无法自己把窗口弄出来。
3. 唯一稳定组合 = 用户自己开微信 + 提权 helper + 窗口保持可见；缺一个就只剩「能收不能回」。
4. 图片密钥（点开一张大图）与 `media_0.db`（播一次语音）两个密钥没拿到，媒体入站因此只有降级文案。

**留下但没上线**：`wx-gateway.py` 的发件箱（`OUTBOX_MAX_TRIES=8`、`OUTBOX_TTL=900`），发送失败排队重试，窗口恢复后补发。没有失败场景实测过，恢复这条线时先验它。

## D47 · QQ 通道回到「旧机登录 + 新机隧道」（2026-10-29 18:25）

**事故**：两台云主机同时跑同一个 QQ 号（10002）的 NapCat。2026-10-29 15:28 旧机 203.0.113.11 上的 NapCat 被拉起，新机 203.0.113.10 立刻收到 `[KickedOffLine] 您的账号已在另一台终端登录`，此后每 2 分钟 `Login Error, ErrType: 1` 重试，用户发消息她收不到、也回不了。

**排查结论**：新机 NapCat 拿不到可用会话（需要扫码，而二维码有效期约 2 分钟，用户不在电脑前）；旧机复用磁盘上的旧会话**可以免扫码快速登录**。因此「登录」只能留在旧机，「大脑」（bridge + node-plugin）在新机。

**决策**：NapCat 只在旧机跑（`systemctl enable napcat`，随机器自启）；新机用 systemd 单元 `napcat-tunnel.service` 常驻 `ssh -N -L 127.0.0.1:3001:127.0.0.1:3001 root@203.0.113.11` 把旧机的 OneBot 11 WS 端口映射到新机本地；新机自己的 `napcat.service` 已 `disable --now`，绝不再抢登录。bridge 配置不用改（仍连 `ws://127.0.0.1:3001/`）。

**为什么不用反向隧道/改 bridge 配置**：新机到旧机的 SSH 是单向可得的（把新机 `~/.ssh/id_ed25519.pub` 追加到旧机 `authorized_keys` 即可），本地转发最省事，且 bridge 一行配置都不用动，出事时换回本机 NapCat 只是 stop 一个单元。

**验证证据**（都是真消息，不是自测脚本）：
- 旧机 journal：`18:25:28 黎曦 | 发送 -> 私聊 (10001) 测试：QQ 已恢复（走新服务器通道）…`，随后 `18:25:37 接收 <- 私聊 (10001) 神了`。
- 新机 bridge journal：`task enqueued … userId 10001 … isOwner true` → `state running` → `done`。
- 新机 queue.db 最新三行 `result_ok=1`，其中 `c0a34a9a…` 的 `text='神了'`、`result_text='啊？什么神了呀…'`。

**代价与注意**：旧机不能停机/重装（它现在是 QQ 会话的唯一持有者，会话丢了就要用户扫码）；两台机器之间的 22 端口必须通；`napcat-tunnel.service` 断了 bridge 会 10 秒后重连，日志里的 `napcat websocket error` 属正常重试。
## D48 · 抖音评论区：只回当前作品用 `?item_id=` 直达，门禁三道（2026-10-29 23:03）

**起因**：用户批了「只开评论区」。首跑 `comments_reply.py --send` 死在 `STEP FAIL 定位评论: 页面上找不到这条评论（text-not-rendered-in-15s）`。

**真因**：评论管理页 `https://creator.douyin.com/creator-micro/interactive/comment` 默认只渲染**最新一条作品**的评论；目标评论在 10-28 那条作品下。右上「选择作品」标签点不动；点作品卡缩略图偶尔能切、写进脚本后 5 次全失败（页面还会 15–20 秒自关）。

**做法**：直接带 query 参数打开 `.../interactive/comment?item_id=<作品id>`，一次到位（实测 6 秒就绪）。作品 id 从只读抓取结果 `comments-*.json` 里取。

**门禁（三道，任缺一条就停）**：
1. `douyin\comments-allow.txt` 必须存在（用户授权当次）；
2. 每日上限 5 条、两条之间 ≥30 秒（`douyin\comments-limits.json`）；
3. `douyin\comments-stop.txt` 存在即全停。

**回复技术要点**：目标评论行下面点「回复」→ 出现**嵌套** `contenteditable`（placeholder `回复 XX：`）→ `insert_text` 后**回读一致**才点「发送」→ 按按钮颜色判可用（黑底白字可用、灰底不可用）→ 发送后再 `document.body.innerText` 里找自己那条确认落地 → 写 `douyin\comments-ledger.json`（累计已回，防重复）。

**验证证据**：2026-10-29 23:03:13 首条真回复落地 —— 作品「主人让我出来赚米…」（`发布于2026年10月28日 22:02`）、评论 `沐泽：哦静静`、回复内容「哈哈被你发现了，关注我，下条接着来。」，截图 `douyin\logs\comments\shots\20261029-230326-01-703227-after-send.png`（页面顶部「回复成功」提示 + 嵌套回复可见），日志 `已发送并回读确认` `台账已记…累计 1 条`。

**降级路径（同期上线）**：`douyin\tools\comments_daily.ps1`（计划任务 `DSH Comments Digest`）每天只读抓取 + 生成草稿并推 QQ，**不写任何东西**；抓取失败不推半截；6 小时内已推过就跳过。发表评论前必须人点头。

**边界**：只回她自己的作品；`--max` 默认 5；第一条真回复后仍保留 `comments-allow.txt`，随时可删。
## D49 · 她的世界往「过日子」上改：先保命、再生产、再奇观；QQ 说说每天最多三条（2026-10-29 23:40）

**起因（用户原话）**：「她（小D）现在在游戏里怎么样了？我感觉她都快要饿死了」「我想让他有一个理想的世界」「多建点建筑，搞生产，迭代工具，建一些奇观」「我要她可以网上学」「可以访问我的 qq 空间，然后发一些说说」。

**现场事实**：她漂在 `(-285, 63, 93)` 野水里，血 1/20、饿 0/20，背包只有面包/熟牛肉和一根木棍 —— 不是没能力，是**没人管优先级**：`explore()` 一直把她往水边带，`eat()` 要等饿到阈值才动手，而溺水判定只看脚下没看退路。

**四条方向（用户拍板，按优先级）**：
1. **保命**：不下水、不夜里乱跑、饿到一半就吃、血少就退。落成 `water-guard.cjs`（陆地校验：目标格与退路都必须是实心非水方块）+ `survival.cjs` 的 `emergencyFood`（饿 ≤ 6 直接吃，不再等）与 `explore()` 的目标预检。
2. **生产**：先田后牧。田 = `farm.cjs`（9x9、39 格耕地、水渠 3 格、成熟小麦 39 棵、圆石矮墙、四角火把、粮仓 + 工作台），离她家 8~20 格，op 的 `/fill` 直接落方块，**不消耗她背包**。
3. **奇观**：`wonder-plan.json` 定稿「岸边的塔」（底 9x9、顶 5x5、7 层、内螺旋梯、石砖 + 磨制安山岩腰带 + 玻璃窗 + 云杉地板 + 火把灯 + 石砖台阶引道），分 7 阶段推进，断点续建（`wonder-progress.json`），一天推一到两阶段。
4. **网上学**：她想学时自己去搜（已有 `web_search` 通道），不为她预设课程。

**QQ 说说（新增需求）**：每天最多 3 条，固定时段 09:30 / 14:30 / 21:30，同一天不重复；内容只写真实状态（位置、血/饿、背包、刚做完的事）。实现：`qq-dsh/whale-craft/zone.cjs`（`post()` 调 NapCat `send_qzone_msg`，这个版本没有读说说列表的接口，所以自己记 `qzone-log.md`）+ `zone-daily.cjs`（用她的口吻写，模型不可用时退回规则版）+ `zone-cron.sh` + 三条 crontab 已装。

**为什么不做「主人在线才发」**：NapCat 这个版本没有可靠的在线状态接口，硬做只能靠「他最近说过话」去猜，会漏发也会错发；改成固定三条固定时间，他反而能预期什么时候看到。

**为什么不让她自己决定优先级**：她的 persona 会「想造一个不用赶时间的地方」，但不会算「血 1 点还往水里走会死」。保命是**外部约束**（代码），审美是**内部表达**（她自己写 plan）。

**验证证据**：农场假 bot 测试 17 项 PASS（`node test-farm.cjs` exit 0）；水位守卫测试见 `test-water-guard.cjs`；她的实时状态从「血 1/饿 0 漂在野水」恢复到「血 20/饿 20 站在自家门口砍树」（`xd status`）。
## D50 · 塔封顶；把「有麦子没面包」「撞同一堵墙」「往水里挖」三处死结解开（2026-10-30 12:55）

**塔**：`wonder.cjs` 第 5 阶段（螺旋梯）的 `stairRing/stairCells` 拿 x 算完当 z 用，验收坐标会落到场地外的 `z=-206`（场地只到 78），所以第 5 阶段永远失败、塔卡在 stageDone=4。改成 x/z 各按场地方向推进后，第 5、6、7 阶段连续通过（42/19/56 条指令），`wonder-built.json` 落成：塔心 `(-204,70,73)`、顶 y=99、7 阶段。日志 `[ALERT] 塔造完了：岸边的塔（7 个阶段）`。

**面包配方缺失**：`bot.recipesFor(bread)` 返回空（客户端这版麦子换不来面包），于是 `wheat>=3` 那道闸门把 `harvestFarm` 永久挡住，人还是饿着。改法：配方缺失置 `state.noBreadRecipe`，收割闸门改成 `wheat>=3 && !noBreadRecipe`，并把该失败的重试间隔放宽到 1 小时。

**砍树**：以前只认 `findBlock` 挑的「最近那棵树」，被挡就每 15 秒撞同一堵墙，白天全耗掉。改法：候选 24 棵逐个试，`standSpotNear()` 按 y=0/+1/-1/+2 与八个方向找能站且线路干的位置。修完第一次就砍到 4 块原木。

**夜里往水里挖**：`nightRest` 泡在水里还往下挖三格，把她埋进更深的水，血从 20 掉到 4.3。改法：`headInWater()` 时不挖；`escapeWater` 的「跳出水面」必须「脚不在水里 + 头不在水里」，并 400ms 后复验（跳的瞬间脚下常有一帧是空气，以前会误判成上岸、把 `waterStuck` 清零，永远升不到 `/tp` 兜底）。

**工作台摆不下**：`placeTable` 把工作台摆在自己脚底下，服务端以「那格里有玩家」拒绝（`Server refused to place crafting_table`）。改法：从身边一圈里挑「下方实心、本位空气」的格子，最多试四格。修完 `做木镐 成功`。

**闲逛走丢**：`explore()` 每趟 8~20 格但没有回家倾向，几个小时后她在 90 格外，而田的触发半径只有 36 格。改法：离家 >55 格时这一趟朝家走（角度偏向 HOME ±0.25 rad）。

**收麦补种 + 余粮入仓**（子代理 434e84d1）：收完一茬就地补种（`placeBlock(耕地, 上)`，无种子则跳过，单格失败只记一条笔记），新增 `storeSurplus` 把超量物资搬进田头箱子（土 32 / 圆石 64 / 种子 32 / 小麦 12），箱子坐标过期按「不存在」处理、不惩罚。测试 `test-harvest.cjs` 42→**65/65 PASS**，`test-water-guard.cjs` 17/17。

**抖音「她的一天」首跑**：12:20 预览与 12:40 发布首次实战。12:20 那次实际失败——包装脚本把 Python 的中文 stderr 经管道送进 PowerShell，编码不对抛 `UnicodeEncodeError`，脚本在推 QQ 前就断了；改成 `PYTHONIOENCODING=utf-8` + 输出先落文件再读。12:40 发布成功：`PUBLISHED_CONFIRMED`、台账 `published`、截图有「发布成功」。

**证据**：`node --check survival.cjs` exit 0；`test-harvest.cjs` 65/65、`test-water-guard.cjs` 17/17、`test-farm.cjs` PASS、`test-wonder.cjs` PASS；云上 `xd status`：血 20/饱食 20，背包 `wooden_pickaxe 1 / coal 2 / torch 2 / cobblestone 3`；`wonder-progress.json` stageDone=7。

## D51 · 她卡在「木镐之后」的四道小门（2026-10-30）

塔完工、木镐做出之后，她在木镐→石镐之间绕了一个半小时。四道门都不是「不会」，是步骤之间互相卡住，逐个修在 `qq-dsh/whale-craft/survival.cjs`。

**配方挑错（真因最隐蔽）**：`bot.recipesFor(acacia_planks.id)` 会返回所有同 id 输出的配方，`recipes[0]` 常常是吃橡木原木的那条，手里只有金合欢 → `bot.craft` 内部校验直接抛 `missing ingredient`，而 `penalize` 只显示这一句，看起来像「材料不够」。这个 mineflayer 版本把「吃掉什么」记在 `recipe.delta`（负 count），`recipe.ingredients` 常是空数组，所以按 ingredients 筛也筛不出来。新增 `pickRecipe(recipes, ids)`：先看 `delta` 里被消耗的 id，再看 `ingredients`，都不中才退回第一条。`makePlanks`（吃哪种原木就挑哪种）、`makeSticks`（吃手里已有的木板）都改走它。

**一次合几份**：`makePlanks` 写死合 2 份，只有 1 根原木时必抛 `missing ingredient`；改成 `Math.max(1, Math.min(2, count(logName)))`。

**挖矿路径**：`mineStone` / `mineCoal` 原来 `goto(GoalNear(矿石坐标, 1~2))`，矿石嵌在石头里根本站不进去，和砍树踩过的是同一个坑。改成 `findBlocks({count: 6~8})` 取候选、`dryLine` 过滤、`digNear(block,label)` 用 `standSpotNear` 找站位再挖，前面几块都失败才惩罚。

**夜里往返**：围屋的 `placeBlock` 被服务端拒绝（`Server refused to place block`）时，`nightRest` 与 `buildShelter` 每 4 秒互相抢一次任务，整夜在「夜里躲一下 / 把自己围起来」之间弹。改成围不起来时同时给「夜里躲一下」加 120 秒退避。

**证据**：`node --check survival.cjs` exit 0；`test-harvest.cjs` 65/65、`test-water-guard.cjs` 17/17；上线后背包从 `acacia_log 6（无木板）` 变成 `acacia_planks 4 / oak_planks 2 / stick 4`，说明金合欢终于能合成了。

## D52 · 她会自己挖竖井了 + 死亡不再清背包（2026-10-30）

**问题**：`mineStone` / `mineCoal` 只用 `findBlocks({maxDistance:48})` 找地表附近的裸露石头，而她活动区是草地+树林，48 格内没有可站位的石头，于是「木镐 → 石镐」这道门一整天都过不去（日志反复 `48 格内没有能走过去的裸露石头`）。

**做法**（子代理 7e844f96，我验收部署）：`survival.cjs` 新增 `mineShaft()`（:478），排在 `STEPS`（:1410）里 `stonePickaxe` 之后、`mineStone`（:1425 同一行）之前。触发条件：有任意镐、`cobblestone < SHAFT_GOAL`（:440）、不在水里。行为：从当前位置挑一个能下镐的方向，挖 1 宽 2 高的阶梯竖井往下走，每 6 格插一根火把，最多 24 格或到 `SHAFT_MIN_Y`，到石头层就地挖 4~6 块。

**安全闸**：`wg.dryLine` + `cutView(holes)`（把本次要挖掉的格子当作空气，否则 dryLine 必报「目标点被方块占着」——这是子代理踩到的第一个坑）；脚下/前方任何一格是 `water`/`lava` 立即停并 30~120 秒退避；`y <= SHAFT_MIN_Y` 直接 5 分钟退避，避免她把自己埋在爬不上来的深度。

**为什么这次值得写进决策**：`keepInventory=true`（`server.properties`，已生效）改变了失败的代价结构。她凌晨淹死一次掉了全部家当（木镐、木板、吃的），之后重建花了一个多小时；现在死亡只掉经验，她可以放心下矿。两件事要一起看：**放宽死亡惩罚 + 给她主动获取石料的路径**，才让「木镐之后」这条线真正通。

**证据**：`node --check` exit 0；`test-harvest.cjs` 65/65、`test-water-guard.cjs` 17/17、新增 `test-shaft.cjs` 27/27；上线 5 分钟后的真实结果——背包出现 `stone_pickaxe 1 / stone_sword 1 / torch 2 / wheat 5`，日志 `[life] 第一次做出石镐`（`2026-10-30T06:52:52.146Z`）。

## D53 · 她卡死 34 小时的看门狗；发布按钮点不动改 DOM 点击（2026-11-01）

**一、她为什么 10-30 23:09 之后只剩独白**
- 现场：`[survive] 四处看看` 之后 34 小时没有任何 `[survive]` 行，`[thought]` 每 10 分钟照常写（那是独立 timer）。
- 机制：`survival.cjs` 的 `tick()` 用 `busy` 做互斥，`try/finally` 里才置回 false；只要某一 `await`（`pathfinder.goto` / `explore`）永不 settle，`busy` 就永远为 true，`tick` 每次进来第一行就 return。
- 修法：① 每个长步骤套 `withTimeout(step(), 150s)`，超时 `hardStop()`（`bot.pathfinder.stop()` + `clearControlStates()`）并 penalize 2 分钟；② 独立 `stallWatch()` 每 15 秒看一眼，`busy` 超过 240 秒就强制松手并 `[ALERT] 卡住了`——这一层不依赖具体卡在哪个 await 上。
- 另修：`fightOrFlee()` 原来「没剑就 return false」，于是「躲怪 ↔ 躲夜」每 6 秒空转；改成没剑也先撤 20 格。

**二、抖音发布按钮点了没反应**
- 现场：`publish2.py` 用真实鼠标点 `(274,788)`，连点 3 次表单毫无变化（没有 toast、没有 disabled），`wait_until` 各空等 90 秒后 `StepFail`。同一坐标在 10-30 12:40 那次是成功的，所以不是坐标算错，是**底部吸底栏/浮层把点击吞了**。
- 修法：第 1 次仍用真实鼠标；第 2、3 次改 `page.evaluate(JS_CLICK_PUBLISH)` 直接在页面里 `button.click()`（挑面积最大的「发布」按钮）。11-01 10:13 第 2 次点击即 `PUBLISHED_CONFIRMED`。
- 顺带：`step_publish` 开头会等「发文助手快速检测」结束（检测中点了也无效），最多 90 秒。

**三、封面改版（用户反馈「封面一片黑」）**
- 旧版是纯暗底卡片（`mean≈33`）；现在整幅用 `douyin\mc-frames\<date>\backdrop` 的真景截图打底，只压顶部/底部渐变，中间画面不压暗（封面 `mean≈98`）。
- 真景来源：`douyin\tools\mc_frames.py`（SSH 隧道 → 127.0.0.1:3017 viewer → Edge/Playwright 截图，`--prep` 先 `time set noon;weather clear;tp …`，`--merge-into` 把多机位合并成一个底图目录），自动剔除纯天空帧（`std<32` 或 `mean>188 && std<46`）。
- 4:3 横封面由 `mc_daily.draw_wide_cover()` 生成 `card-01-<wide>.png`，`publish2.step_cover()` 会自己找同目录的 `-wide` 文件补上（抖音原来提示「横封面缺失」）。
- 标题去重：`--avoid-titles` 读 `publish-manifest.json` 已用标题，数字抹平后同句式也算撞。

## D54 · 合成「updateSlot did not fire」的真因是窗口模型漂移；每次动手前同步+清格（2026-11-01）

**根因链**（子代理 f7288d94 查，我独立复核日志与 md5）
1. `updateSlot:0 did not fire within timeout of 20000ms` 只可能来自「服务端 20 秒一个 `set_slot` 都没回」——`prismarine-windows/lib/Window.js:286-293` 是无条件 emit。
2. 她进程里的窗口/背包模型与服务端漂移：模型里 `acacia_log 6 + oak_planks 1`，服务端重放的真值是 `acacia_planks 8 + acacia_log 1`。
3. 模型错 → `craft.js` 算出的点击落在服务端认为无效的槽上；1.17.1+ 服务端只在它认为客户端记录过期时才回包（`mineflayer/lib/plugins/inventory.js:853-870` 注释），于是 `putAway(0)` 干等 20 秒。
4. 漂移不自愈：mineflayer 的 2x2 合成路径（`craft.js:11-37`）只有工作台成功时才 `_syncWindow`+`closeWindow`，2x2 全程不同步不关窗，`grabResult`/`putMaterialsAway` 还在本地写预测。
5. 放大器：`tick()` 的 `withTimeout(step(),150000)` 超时后**不取消底层 step**，被放弃的 craft 仍在跑，下一轮再起一份 → 两份合成叠着改同一个模型，所以「重启也只好像一阵子」。

**改法**（`qq-dsh\whale-craft\survival.cjs`，1665 行，md5 `d8a9ac3da9592a7505131773247f7989`，本地=云上）
- `:405` `makeSticks` 门槛 `planks() < 1` → `< 2`（木棍吃 2 块木板）。
- `:423` `craftAtTable` 离工作台 >3 格先 `GoalNear(...,2)`——隔 8 格点方块服务端不认，`windowOpen did not fire` 连打 12 次。
- `:726/:755` window_click 流水 + `craftState()` 三行失败诊断。
- `:769 craftBusy` 合成门闩、`:771 lastCraftError`。
- `:772 aliveWindow()`、`:788 syncInventory()`、`:798 clearCraftGrid()`、`:823 craftRetry()`：每次合成前探活窗口 → `_syncWindow(bot.inventory)` → 失败清格再重试。
- `:1415 bakeBread` 不再绕过 `craftRetry`。
- 新增 `qq-dsh\whale-craft\tools\probe-craft.cjs`（baseline / --dirty / --race / --desync 四模式探针，用 ProbeBot* 号不踢她）。

**验收证据（我自己跑的）**
- 本地 `node --check` ok；`test-harvest` 65/65；`test-water-guard` 17/17；`test-shaft` 27/27。
- 云上 md5 与本地一致、1665 行、`whale-bot`/`whale-mc` active；`journalctl --since 10:22 | grep -c updateSlot` = **0**。
- 真合成日志：`[craft] 做工作台 成功，用时 251ms`、`做木板 成功，用时 201ms`（11:08:29/31），此前还有 `做石镐 成功 441ms`。
- 背包已成型：`stone_pickaxe 1 / stone_sword 1 / cobblestone 15 / andesite 10 / acacia_planks 12 / wheat 12`。
- 行为链恢复：`四处看看 → 做工作台 → 把原木做成木板 → 砍树 → 打猎：cow → 吃饭 → 砍树`。

**残余风险**
- 「服务端为何完全静默」没 1:1 复现，属推断；解药已被 5 次生产合成验证。
- `craft.js` 的 `windowCraftingTable` 是模块级缓存窗口，失效后仍可能点到旧对象——要改 `node_modules`，超出边界未做。

## D55 · 石头→铁器整条链上线；竖井里掏壁龛摆工作台；whale-bot 看门狗（2026-11-01）

**一、熔炉线**（`survival.cjs` 1665 → 2053 行，md5 `634c4bc5cf8b741cb8eef7783ab953db`，本地=云上）
- 新增：`craftFurnace` / `placeFurnace` / `makeCharcoal` / `smeltIron` / `craftIronTools` / `mineIron`，外加 `pickFuel`（煤→木炭→木板）、`furnitureSpots`（显式跳过脚下那格）、`withCraftLock`、`openFurnaceHere` / `smeltBatch`。
- D54 契约照做：开炉前 `aliveWindow()` + `syncInventory()`，取完产物 `close()` 再同步；整段在 `craftBusy` 门闩内，开炉失败退避 120 秒不重试。
- `mineShaft` 的「选方向 / 挖三格再下」抽成 `pickShaftDir` + `shaftCutStep`，`ironDive` 复用同一份水/岩浆判据。
- `STEPS`：`:1934` 石镐之后接 `craftFurnace, placeFurnace, makeCharcoal, smeltIron, craftIronTools`（:1937），`mineIron`（:1939）单独排在 `explore` 前。
- 测试：`test-smelt.cjs` 新增 40 条断言；`test-harvest` 65/65、`test-water-guard` 17/17、`test-shaft` 27/27 全绿。

**二、竖井里摆不了工作台（现场 bug）**
- 现象：`待机 → 烤面包 → 摆工作台` 死循环，`摆工作台 失败：附近找不到平地`。`findFlatSpot()` 要求「脚下实心 + 两格空气」，1 格宽的竖井里永远不满足。
- 改法：新增 `digPocket()`（`survival.cjs:367`），y<64 且找不到平地时，朝脚边四向掏一个 1x2 壁龛再摆；上方是水/岩浆的方块一律不碰。`placeTable` 里改成 `let flat = findFlatSpot(); if (!flat && y<64 && await digPocket()) flat = findFlatSpot()`。

**三、她昨天 12:31 被停过一次**
- 现场：`whale-bot` 变 inactive，日志只有一句 `Stopping XiaoD MC bot...`，notes 停在 04:32Z；没找到是谁停的（bash_history 空、auth.log 无对应会话）。
- 处置：手动 start 恢复；新增 `whale-bot-guard.service` + `whale-bot-guard.timer`（`OnCalendar=*:0/3`，每 3 分钟 `systemctl is-active --quiet whale-bot || systemctl start whale-bot`），已 enable 并验证 NEXT 正常。

**验收证据**
- `[craft] 烧木炭 成功，用时 20601ms，charcoal+2（燃料 charcoal）`、`[craft] 做熔炉 成功，用时 770ms`。
- 背包：`furnace 1 / charcoal 2 / oak_planks 9 / stone_pickaxe 1 / stone_sword 1 / cobblestone 7`。
- 行为链：`四处看看 → 做熔炉 → 挖竖井（y=63，圆石 7）`。
- 已知残余：她频繁掉水里（`水里往上划` 反复出现，`划水上岸没成功（Path was stopped…）`），挖竖井会挖穿水层——下次要给她加「井壁有水就放弃这口井并封顶」。

## D56 · 井壁见水就封井 + 横着开矿道找铁（2026-11-01）

**一、井壁灌水（现场：她两天里反复「水里往上划」、`划水上岸没成功（Path was stopped…）`）**
- 原来的判据只看竖井正下方与切口那条线（`shaftCutStep` 里的 `feet/head/body/floor` + `wg.dryLine`），看不到**侧壁**：一格宽的井挨着水塘时，挖开那一格水会从侧面灌进来，等察觉到人已经在井底。
- 改法：新增 `sideWet(x,y,z)`（`survival.cjs:536`），检查目标格四邻 + 头上一格；命中就返回 `kind:'side-wet'`（`:570`）。`mineShaft` 退避 3 分钟换地方重开（`:622`），`ironDive` 同样处理（`:953`）。
- 测试：`test-shaft.cjs` 加 J1–J4（侧壁有水时一镐都不下、记「井壁外是水」、进 3 分钟退避），27 → **31/31**。

**二、横着开矿道（原来下到 y≤56 看不到矿就只会说「这一层看不到铁矿」）**
- 新增 `stripMine()`（`survival.cjs:1009`，`STRIP_STEPS = 24` 在 `:676`）：y ≤ 56 且附近 48 格没有铁矿时，四向各探 6 格挑一条干净方向，开一条 2 格高、最深 24 格的矿道，每 8 格插火把，每 4 格抬头找矿，看见就用 `digNear` 去挖。
- 边界：`IRON_FLOOR_Y + 8` 以下不横开（离岩浆太近）；脚下/前方/侧壁见水或岩浆立刻收手并退避 3 分钟；没镐或已经有铁镐就不干。
- `STEPS` 里排在 `mineIron` 之后、`explore` 之前（`:2054`），导出见 `:2143`。
- 测试：`test-smelt.cjs` 加 K1–K9（矿层以上不横开、没镐不挖、真挖出 48 镐的 2 格高矿道、人往前走了、笔记记格数、四面侧壁是水时一格不开并退避 2 分钟、STEPS 次序），40 → **49/49**。

**当前全绿**：harvest 65、water-guard 17、shaft 31、smelt 49、farm、wonder，合计 **162 条断言**。部署 md5 `09044ff463c35c3c5dd10b6819495050`，本地=云上一致。

## D57 · keepInventory 写了却没生效 + 幻翼把她的家底打光（2026-11-01 13:20 事故）

**现场**：13:22 她连吃两拨幻翼（`[chat] XiaoD was slain by Phantom`），死在 `(-162.5,68,60.49)`，`xd status` 背包直接变成 `{}` —— 按 D52 应该保背包的。

**真因（时间差）**：`whale-mc` 服务起于 `2026-10-30 14:36:48`，而 `server.properties` 里那行 `keepInventory=true` 是 **14:37** 才写进去的（`ls -la` 显示 mtime `Oct 30 14:37`）。服务端只在启动时把这些项读成 gamerule，晚写一分钟就等于没写。之前「已生效」的判断是错的——中间从没重启过 `whale-mc`。
另外 `doInsomnia` 从来没配过，幻翼按期来，她夜里没床没掩体就是活靶子。

**处置**：
1. `server.properties` 增 `doInsomnia=false`、确认 `keepInventory=true`（备份 `server.properties.bak.<时间戳>`）。
2. `systemctl restart whale-mc`（等 `Done (` 出现，实测 38 秒）→ `systemctl restart whale-bot`。
3. 补发起步工具：`give XiaoD stone_pickaxe 1 / stone_sword 1 / crafting_table 1 / acacia_planks 8 / stick 4 / cooked_beef 8 / torch 8`。
4. 复核：`xd status` → `hp 19.17 / food 20`，背包七件齐。

**教训（下不为例）**：
- 改 `server.properties` 之后必须重启 `whale-mc` 并确认 `ActiveEnterTimestamp` 晚于文件 mtime，否则「改了」只是文件改了。
- 判断「某条 gamerule 是否生效」看服务启动时间，不看文件内容。
- 她死了会掉东西，而 `keepInventory` 真正生效前每一次死亡都是净损失——以后给她调环境，先确认这条再说别的。

## D58 · 别在野山上过夜、也别一遍遍重做熔炉（2026-11-01 13:45）

**观察到的问题**
- 她跑到 `(-156, 98, 120)`（离家 130 多格、在山上），夜里就是「夜里躲一下 ↔ 把自己围起来」来回切，两个 step 谁也干不完。
- 熔炉摆了又丢：`摆熔炉 成功，在 (-200,70,36)` 之后走远，`furnaceNear()` 只认 16 格 → 以为没有炉子，又做一个新的（8 块圆石一个）。

**改法**
1. `nightRest`（`survival.cjs:242` 后）加「天黑先回家」：`gapHome > 24` 就 `goto` 家门口，走不回去也记一笔（节流 5 分钟）——不在野地刨坑过夜。
2. `furnaceNear(maxDistance = 32)`（`:687`，原 16）：炉子摆过一次就算有，不再重复合成。
3. `explore()` 加硬闸（`:1470` 后）：离家 > 60 格直接 `penalize('闲逛', 90s)` 并让位——把机会还给回家、挖矿、收麦这些正事。

**验证**：六套测试仍全绿（harvest 65 / water-guard 17 / shaft 31 / smelt 49 / farm / wonder），部署 md5 `42a43689dd2c62c85f96ed27b2fdfa22`，本地=云上一致，`whale-bot` active。

## D59 · 1.21.11 的 gamerule 是 snake_case：`keepInventory` 一直没生效（2026-11-01）

**症状**：她每次死，背包清空（`[ALERT] 死了… 背包里的东西掉在那儿了`），`server.properties` 里明明写着 `keepInventory=true`。

**根因（两条叠在一起）**：
1. 原版 `server.properties` **没有** `keepInventory` 这个键，它只是被我们手写进去的一行装饰；真正的开关是 `level.dat` 里的 gamerule。
2. MC 1.21.11 起 gamerule 全部改成 snake_case：`keep_inventory` / `spawn_phantoms`。写 `gamerule keepInventory true` 时服务端只回一句
   `Incorrect argument for command` + `gamerule keepInventory true<--[HERE]`，`<--[HERE]` 落在**行尾**，容易误读成「命令没权限」。

**改法**：
1. 开 RCON（`server.properties`：`enable-rcon=true`、`rcon.password=whale-rcon`、`rcon.port=25575`），新增 `/opt/whale-craft/rcon.py`（纯 stdlib 的极简客户端，`python3 rcon.py 'gamerule keep_inventory true'`）——控制面 `xd cmd` 有允许列表，`gamerule`/`op` 被拒（日志 `不在允许列表里: gamerule`）。
2. `viewer-attach-bot.cjs` 进世界时用 op 身份钉一遍：`/gamerule keep_inventory true`、`/gamerule spawn_phantoms false`。
3. 死完复活回尸体点：`survival.cjs` 的 `death` 处理记下 `state.diedAt`，`spawn` 时若离家/离尸体点 > 32 格就 `/tp` 回去捡包（新增 `bot.on('spawn')`，`survival.cjs:2163` 起）。原来复活点在世界出生点，离家 160 格，走回来天又黑。

**验证**：RCON `gamerule keep_inventory` → `currently set to: true`；`give XiaoD stone_pickaxe 1` + `give cooked_beef 5` + `/kill XiaoD` 后 `xd status` 背包仍是 `{"stone_pickaxe":1,"cooked_beef":5,"acacia_log":6}`。

**教训**：判断 gamerule 生效只能靠「死亡后背包是否还在」这种实测，别信 `server.properties` 里的键；`<--[HERE]` 标记的位置说明是**哪个 token** 解析失败，行尾标记 = 名字不认识，不是权限不够。

## D60 · 影版视频按「大肥鱼」品类套路改三处（2026-11-01）

调研记录在 `douyin\docs\genre-teardown.md`（227 行，逐条带来源）。三条与事实核对过的结论：
那条 42,922 赞的片子是第三方「饲养员视角」二创，不是「我不是邪恶大肥鱼」本人发的；
该品类靠转发扩散（转/赞 52.7%、藏/赞 10.0%），靠冲突与越界触发转发，不靠画面精度。

据此改了三处：
1. **冲突句**：`douyin\tools\mc_film.py` 新增 beat 类型 `clash`，只从她自己写过的短句（7–12 字）里挑含
   「不认/凭什么/烦/不甘心/再试」等词的句子，**不替她编态度、不要脏话**；`_QUOTE_CLASH` 是词表。
2. **今日账本卡**：新增 beat 类型 `ledger`，收尾前把当天三个真数字（记下的事 / 倒下 / 第一次做成）
   盖成一页 + 红章「已记下」；数据不足两条就不出这张卡。
3. **连载编号**：`douyin\tools\mc_daily_publish.py` 新增 `episode_no()`，标题模板变成
   `她的世界 D{n}｜<hook>`（n = 台账里已发出的 MC 集数 + 1）。`SERIES` 仍是「她的世界」。

验证：`python douyin\tools\test-mc-film.py` 73 条断言全绿；真片 `douyin\out\film2-20261030.mp4`
17 个 beat / 32.72 秒 / 1080x1920 / h264+aac，账本卡与冲突句都进片。

## D61 QQ 通道三个「她答应了却做不到」的死结（2026-11-01）

用户问「小号还有什么问题要修改」，按证据查出三处，全部修掉：

1. **语音从未发成功**（7 天 65 次 `retcode 1200`）。真因不是 TTS 坏了，而是跨机路径：
   桥接把本机绝对路径塞进 `record` 段，NapCat 跑在旧机（D47 隧道方案），那边没有这个文件。
   改法 `bridge/src/dispatch.js`：新增 `segmentFile()`，本地文件一律读成 `base64://<base64>`，
   `scheme://` 原样透传；读不到则 WARN 并退回原路径。
   线网实测：115 KB mp3 以 base64 发 `send_private_msg` → `{"message_id":1291174846}`。
2. **慢回合完全静默**（`turnTimeoutMs: 180_000` 超时后 `result_text=''`，什么都不发）。
   改法：`timing.slowAckMs=22_000` 到点先垫一句「在呢，我想一下。」（只在私聊+主人+需回复+非主动），
   终态失败时补一句「我这边卡了一下，你再说一次好吗？」（群里保持沉默，因为群聊不该被刷）。
3. **提醒功能根本不存在**。新增 `bridge/src/reminders.js`（store + 15 秒 ticker）、
   `POST /node/remind`、插件 `lib/remind.js` 的 `remind` 工具（`parseWhen` 支持 `19:00`/`明天 08:30`/`+20分钟`/ISO）。
   语义：最多排 30 天内、过期超 30 分钟直接判死不补发、发送失败只试一次。

验证：`node --test "test/*.test.js"` **236/236**；云上排一条 90 秒后的提醒 → `reminder fired lateMs=2723`，
`reminders` 表 `fired_at` 已写，主人那边同步收到消息。