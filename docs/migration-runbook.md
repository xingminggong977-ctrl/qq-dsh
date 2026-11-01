# 迁移手册：QQ 机器人整机搬迁（阿里云 4核8G → 2核4G）

> 目标不是「搬过去能跑」，而是「搬过去比现在干净」。旧机带病运行的东西，
> 迁移时逐条定性：修掉、或写进已知限制。

## 0. 四条铁律

1. **新机验证通过前，旧机不停、不改、不退。** 切换是最后一步。
2. **迁移窗口内不给旧机做任何配置变更。** 两套状态分叉是这类事故的头号成因。
3. **唯一必须人工的步骤是 QQ 登录。** 而且只需扫这一次（见 §6）。
4. **不许旧机没停就在新机起 QQ。** 同号双端在线互顶，是 ErrCode 168 风控的头号触发器。

## 1. 目标机型

| 项 | 选型 | 依据 |
|---|---|---|
| 规格 | 2 vCPU / 4 GB / 40 GB ESSD | 实测峰值内存 686 MB、负载 0.03；4 GB 是给 OOM 留余量的下限 |
| 系统 | Ubuntu 22.04 LTS | 与旧机同版本，`/opt/QQ` 依赖不用重新验证 |
| 入站 | **只开 22** | bridge 绑 `127.0.0.1:8787`，**没有任何公网业务端口** |
| swap | 2 GB | 旧机 swap=0，见 §5 暗伤 2 |

占用实测（旧机）：QQ 614 MB + NapCat 238 MB + QQ 登录态 219 MB + asr-venv 494 MB
+ 业务 32 MB ≈ 1.6 GB。走云端转写后 `asr-models`（464 MB）不再需要。

### 1.1 照着下单（2026-10-27 定稿）

| 下单项 | 选这个 | 为什么 |
|---|---|---|
| 计费方式 | **包年包月** | 这是 7×24 常驻服务，按量付费比包年贵一倍以上；出问题随时可退，不锁死 |
| 地域 | **华东1（杭州）** | 与旧机同地域。换地域等于换出口 IP 段，QQ 那条长连接的稳定性和风控判定都会变，没有理由冒这个险 |
| 实例规格 | **通用型 g8i，2 vCPU / 4 GiB**（`ecs.g8i.large`） | 实测负载 0.03、峰值内存 686 MB。**不要选突发性能型 t6/t5**：CPU 积分耗尽会被限频，而 QQ 客户端是 Electron，限频时最先出问题的就是它 |
| 镜像 | **Ubuntu 22.04 LTS 64 位** | 与旧机完全同版本，`/opt/QQ` 的依赖库不需要重新验证 |
| 系统盘 | **ESSD PL1，60 GB** | 现在只用 11 GB，但要把 `/opt/asr-models`(464 MB) + 备份 + 迁移临时包（265 MB ×2）都放得下；40 GB 会紧，差价极小 |
| 公网带宽 | **按使用流量，峰值 5 Mbps** | 全年几乎只跑文本和少量语音/图片，固定带宽是白付月租 |
| 安全组 | **只放行 22**，来源限制为你自己的 IP | bridge 绑在 `127.0.0.1:8787`，**没有任何业务端口需要公网暴露** |
| 自动快照 | 开启，每天一次，保留 7 天 | 迁移当天出问题，回滚成本降到一条命令 |
| swap | 开好机后建 2 GB swapfile | 旧的 4 GB 交换区本来就是 0，内存不足时直接 OOM 杀进程（见 §5 暗伤 2） |

关于语音：如果百炼的 key 贴上了并且实测稳定，`/opt/asr-models`（464 MB）和
`/opt/asr-venv`（494 MB）都不必搬，新机磁盘和内存都更宽松。但**在云端转写跑通之前
不要删旧机上的这两样**——它们是本地兜底，云端挂掉时唯一能听见声音的路。

## 2. 旧机上到底跑着什么（迁移清单的事实基础）

- **5 个服务**（全部 enabled + active）：`napcat`、`dsh-qq-bridge`、`dsh-qq-agent`、
  **`dsh-qq-crisis`（危机词监控）**、**`dsh-qq-friend`（自动加好友）**。
  漏掉后两个不会报错，只会静默失效。
- **15 个 unit**：上面 5 个 + `dsh-qq-healthcheck.{service,timer}` +
  `dsh-qq-napcat-watch.{service,timer}` +
  `dsh-qq-nightly-{digest,report,weekly}.{service,timer}`。
- **3 个 cron**：`/etc/cron.d/dsh-qq-{backup,diary-merge,github-backup}`。
- **13 个脚本只存在于 `/usr/local/bin`**（源码在 `deploy/bin/`，由
  `deploy/install-host-scripts.sh` 安装）：`dsh-qq-alert.mjs`、`dsh-qq-backup.sh`、
  `dsh-qq-healthcheck.sh`、`dsh-qq-napcat-watch.sh`、`backup-to-github.sh`、
  `push-notify.sh`、`diary-automerge.sh`、`dsh-qq-post-migration-audit.sh`，以及 5 个手工运维工具
  `check-task`、`recent-tasks`、`enqueue-owner-text.sh`、`seed-corrections.sh`、`preview-corrections.sh`
  （这 5 个原先只存在于旧机磁盘上，2026-10-27 比对时才发现没版本化，已收回仓库）。
- **配置目录 3 个**：`/etc/dsh-qq-bridge/env`、`/etc/dsh-qq-agent/`、`/etc/dsh-qq-nightly/env`。
- **数据目录 2 个**：`/var/lib/dsh-qq-bridge`（`dshqq:dshqq` 700，含 `queue.db`+WAL）、
  `/var/lib/dsh-qq-agent`（root，26 MB 工作区与记忆）。

## 3. 时间线

| 时点 | 动作 | 谁 |
|---|---|---|
| T-1 天 | 新机开通 → `harden-host.sh --apply` → `check-host.sh` 全 PASS | 我 |
| T-1 天 | 新机装 QQ(NT) + NapCat + node 24 + python venv，**先配上 `-q` 再首次启动** | 我 |
| T-0 ① | 旧机 `migrate-export.sh`：停 bridge → checkpoint → 打包 → 自动拉起 | 我 |
| T-0 ② | 包传到新机 → `migrate-restore.sh` | 我 |
| T-0 ③ | `migrate-verify.sh`：**不启 QQ**，59 项检查 | 我 |
| T-0 ④ | 启动 napcat 登录 QQ（**扫这一次码**）→ 立刻重启验证不再要码 | 需你扫一次 |
| T-0 ⑤ | enable 五个服务 + 端到端四条验收 | 我 |
| T-0 ⑥ | 改本机外部引用（§7） | 我 |
| T-7 天 | 旧机停机；再观察 7 天后退订 | 你决定 |

## 4. 关键步骤

### ① 导出（唯一一段真停机，约 30–90 秒）

`migrate-export.sh` 的顺序是硬性的：**停 `dsh-qq-bridge` → `PRAGMA wal_checkpoint(TRUNCATE)`
→ 校验 `queue.db-wal` 归零 → `integrity_check` 必须 ok → 打包 → 自动拉起**。

停机的原因见 §5 暗伤 6：`queue.db-wal` 有 3.4 MB，是主库的 10.7 倍，只拷 `queue.db`
会丢掉 WAL 里全部未合并写入，而文件大小看起来完全正常。脚本还会把 checkpoint 之前的
WAL 三件套另存一份打进包，真出问题可以退回原始状态。

### ② ③ 不带 QQ 的自检

QQ 登录是独占资源，新旧机不能同时登，所以先验不依赖 QQ 的部分。此时 bridge 日志里会有
NapCat WS 连接失败重试的告警——**这是预期的**，说明 ④ 之后它才能工作。

### ⑤ 端到端四条验收（缺一不可）

| 验收 | 动作 | 期望 |
|---|---|---|
| 收发 | 主人私聊「在吗」 | 有回复；`audit-*.jsonl` 新增 `private_reply ok:true` |
| 语音 | 发 3–5 秒语音 | `voice transcribed`，且**耗时 < 2 s**（云端转写生效的标志） |
| PC 通道 | 私聊「在我电脑上跑一下 dir」 | `pc_exec` 返回目录列表 |
| 定时 | `systemctl list-timers dsh-qq-nightly-digest.timer` | 下次触发 = 明天 03:00 |

## 5. 暗伤清单

| # | 暗伤 | 证据 | 修法 | 状态 |
|---|---|---|---|---|
| 1 | 每次重启都要扫码 | `launcher.sh` 无 `-q`；两次重启都要求扫码，其中一次扫完触发 ErrCode 168 | 加 `-q 10002`（已 apply，备份 `launcher.sh.bak-2026...`） | **已修，待下次重启验证** |
| 2 | swap=0 | `free -m` Swap 全 0 | `harden-host.sh` 建 2G swap + swappiness=10 | 脚本就绪 |
| 3 | 无 sqlite3 CLI | 命令不存在 | `harden-host.sh` 按需 apt 安装（迁移脚本已用 python3 stdlib 兜底） | 脚本就绪 |
| 4 | journald 无上限 | 64 MB，未配 `SystemMaxUse`；**drop-in 目录本身都不存在** | `harden-host.sh` 建目录 + 200 MB | 脚本就绪 |
| 5 | 真实日志在 `/var/log/dsh-qq-*.log`，原先的 logrotate 目标全是空集合 | 实存 6 个日志文件 | logrotate 覆盖 `/var/log/dsh-qq-*.log` | 脚本就绪 |
| 6 | **WAL 未 checkpoint** | `queue.db` 323584 / `-wal` 3481432（10.7×）/ `-shm` 32768 | 导出时停服 + `wal_checkpoint(TRUNCATE)` | 已在导出脚本中 |
| 7 | 健康巡检只巡 3 个服务 | 漏 `dsh-qq-crisis`、`dsh-qq-friend` | `deploy/bin/healthcheck.sh` 补成 5 个 + `install-host-scripts.sh` 安装 | **已修**（新机巡检脚本含 5 个） |
| 8 | 主机脚本只存在服务器上，备份不覆盖 | 备份脚本只打 agent 数据；另有 5 个运维脚本从未进过仓库 | `deploy/bin/` 版本化（13 个）+ 安装器；新机核对 13/13 与源码逐字节一致 | **已修**（5 个运维脚本是 2026-10-27 新旧机比对时才补回的） |
| 9 | 备份脚本漏 bridge | 无 `/var/lib/dsh-qq-bridge`、`/etc/dsh-qq-bridge/env`、NapCat 配置、unit、cron | 2026-10-27 重写 `deploy/bin/backup.sh`：12 项必备 + 12 项可选 + 15 个 unit + 主机脚本；`queue.db` 走 SQLite 在线备份 API 并跑 `integrity_check` | **已修，实测 576 成员 / 5.5 MB / 快照 742 行** |
| 10 | 备份「成功」不可信 | `tar … 2>/dev/null \|\| true`，任意路径读失败仍报成功 | 重写后：清单缺项即失败 → tar stderr 非空即删包失败 → `gzip -t` → 关键路径逐个验在包内 | **已修** |
| 11 | ASR 单条 9 秒 | 本地 faster-whisper small int8；纯 Python 循环只 0.5 s，说明是模型本身慢 | 云端 paraformer-v2 适配器 + 百炼 key 已写入 | **已启用：实测 1953 ms** |
| 12 | 看门狗只告警不重启 | healthcheck 只采问题不 systemctl restart | 暗伤 1 就绪后才敢开自动重启 | 受阻于 1 的验证 |
| 13 | swappiness 被云厂商覆盖 | 阿里云自带 `/etc/sysctl.d/99-apsara-sysctl.conf` 设 0 | 用 `99-dsh-qq.conf`（字典序在后）覆盖 | 脚本就绪 |
| 14 | `.bak` 残留 | `/usr/local/bin/dsh-qq-healthcheck.sh.bak-*` | `harden-host.sh` 只清这一种模式 | 脚本就绪 |
| 15 | `dsh-resolve.js` 曾硬编码 Windows 路径 | 已改 `ANCHOR_CANDIDATES` + `DSH_INSTALL` | — | 已修 |
| 16 | root 密码未轮换 | sshd 已 `passwordauthentication no` | 仍未处置 | 待你决定 |
| 17 | 坏提案残留 | `proposals/2026-10-26/` 三份路径是模型编的 | `apply-proposal.sh` 会拒绝越界路径 | 待你决定 |

**不搬的东西**：`/opt/dsh-qq-bridge.old`、`/opt/dsh-qq-agent/node-plugin.{old,prev}`、
`/var/backups/dsh-qq`、`/var/log/dsh-qq-*.log`、`/opt/asr-models`。

### 5.1 迁移包不带这四样，必须人工补（合计约 1.3 GB）

`migrate-export.sh:404-410` 原文就写着它们不在包里。包内只有 `/opt/napcat/launcher.sh`
和 `/opt/napcat/napcat/config` 两小份，别以为还原完就能起服务。

| 路径 | 体积 | 新机怎么来 |
|---|---|---|
| `/opt/QQ/` | 614 MB | 装官方 QQ（与旧机同架构同来源） |
| `/opt/napcat/napcat/` | 238 MB | NapCat 官方一键脚本；配置由迁移包还原 |
| `/opt/asr-venv/` | 494 MB | `init-new-host.sh` 第 6 步重建（钉 faster-whisper 1.2.1 + ctranslate2 4.8.3） |
| `/opt/asr-models/` | 464 MB | 云端转写跑通就不用装；要本地兜底才下载 |

**版本钉死有据**：旧机 `/opt/asr-venv` 实测 `faster-whisper 1.2.1 / ctranslate2 4.8.3 /
numpy 2.2.6 / av 17.1.0 / python 3.10.12`，这套已经跑通过转写。换版本会连带换掉
CTranslate2 的 int8 算子与分词器行为，迁移前后结果不可比。

`init-new-host.sh` 的 Go/No-Go **只判系统底子**（apt / node / 用户 / 目录 / venv），
上面四样进的是另一张「需要人工补」清单 —— 因为 `migrate-restore.sh` 本身不需要它们，
但**服务起不来**。两张表要一起看。

## 6. QQ 登录：新机要扫一次，之后不用再扫

`-q 10002` 只决定「登哪个号」，不生成凭据；凭据在磁盘
（`/root/.config/QQ/global/nt_db/login.db` 三件套 + `nt_data/msf/machine-info` 里的伪 MAC
设备指纹 + 账号目录 `nt_qq_2bfee1e17135a558f4d38470a7bc6200`，目录名不是 `md5(uin)`，无法推算）。
票据与设备指纹、出口 IP 一起参与服务端判定，**跨机器免扫码不可靠**。

实际收益：扫码次数从「每次重启一次」降到「一台机器一次性」。扫完这一次后，
崩溃自动拉起、重启、换版本都不再需要人。

## 7. 迁移后必须改的外部引用

新机 IP 变了，这三处硬编码必须同步改，否则会「服务都正常但电脑连不上」：

1. `C:\Users\lenovo\.dsh-qq-pc\config.json` → `baseUrl` 与 `tunnel.host`
2. 本机 SSH 隧道：`ssh -N -L 18790:127.0.0.1:8787 root@<新IP>`
3. `qq-dsh/pc-agent/config.example.json` 第 20 行 `tunnel.host`
4. `qq-dsh/deploy/pull-persona.ps1` 第 18 行 `$Remote` 默认值

> 2026-10-27 复核：`deploy/*.sh` **没有**写死旧 IP（只有上面两处样例文件和文档提到）。
> 真正必须改的只有第 1 条与本机的隧道命令；2–4 是样例/默认值，改了能省下次的手工。

## 8. 回滚

旧机 7 天内保持可启动（只 `stop`，不 `disable`、不卸载）。回滚 = 旧机 `systemctl start`
五个服务 + 改回 §7 三处引用 + DNS/IP 指回。约 10 分钟。

回滚会丢新机上那段时间的消息队列，回滚前先导出 `queue.db` 与 `audit/`。

## 9. 迁移后 24 小时观察

- [ ] 五个服务 `active (running)`，`NRestarts` 不再增长
- [ ] `journalctl -u dsh-qq-bridge --since '24 hours ago' | grep -c 'voice transcription failed'` → 0
- [ ] `audit-*.jsonl` 持续增长，`ok:false` 占比 < 5%
- [ ] `free -m` swap 已用但 < 30%；`df -h /` < 60%
- [ ] 03:00 夜班、08:30 早报各触发一次
- [ ] **连续两次 `systemctl restart napcat` 都不要求扫码**（暗伤 1 的最终验收）

一条命令核对上面全部（含 §2 清单与 §5 暗伤）：

```bash
sudo bash /usr/local/bin/dsh-qq-post-migration-audit.sh
# 2026-10-27 实跑：50 pass / 0 warn / 0 fail
```

## 10. 换机后才暴露的两个事实（2026-10-27）

### 10.1 新机 `github.com:443` 不通，异地备份换了传输层

在杭州节点实测：

| 目标 | 结果 |
|---|---|
| `github.com:443` | **TCP 超时**（`git push` 必挂，原 08:05 cron 每天静默失败） |
| `github.com:22` | TCP 能连，但 SSH banner 收不到（中间设备只放行握手） |
| `ssh.github.com:443` | TCP OPEN，无部署密钥时 `git ls-remote` 128 |
| `api.github.com` / `uploads.github.com` / `codeload.github.com` | 全通（`/zen` 200、uploads 302） |

结论：**不是没网，是 github.com 主站这个域名在这台机器上不可达**。于是把
`deploy/bin/backup-to-github.sh` 从 `git push` 改成 **Releases 资产上传**——同一个私有仓库、
同一个 PAT，只走 `api.github.com` 与 `uploads.github.com`：

- release tag 固定 `backup`（不存在就建，实测 id 425630713）
- 每次上传 `dsh-qq-<UTC时间戳>.tar.gz` + `MANIFEST-<时间戳>.txt`，上传后**用远端 `size` 与本地字节数比对**，不一致即失败
- 只留最近 7 份，按 `created_at` 倒序删
- 失败时 `push-notify.sh` 微信推送 + `exit 1`，不再静默
- 实测 17 秒完成（5.0 MB），连跑两次都 `exit=0`

若以后换到能连 github.com 的机房，改回 `git push` 更省事——但先跑一次
`timeout 8 bash -c 'cat </dev/null >/dev/tcp/github.com/443'` 再决定。

### 10.2 备份包现在覆盖「照着就能重建一台」

旧包只有三个数据目录，真出事时连 QQ 都登不回来。新包（`dsh-qq-backup.sh`）必备 12 项：
`/opt/dsh-qq-agent`、`/var/lib/dsh-qq-agent`、三份 `env`、`queue.db`、NapCat 配置与
`launcher.sh`、`.credentials.yaml`、`llm-deepseek`、profile 的 `cordis.patch.yml` +
`package.json`；再加 12 项可选（cron、logrotate、sysctl、7 个主机脚本）与全部
`/etc/systemd/system/dsh-qq-*` 单元。实测 576 成员、5.5 MB，包内 `queue.db` 快照
`integrity_check=ok`、742 行。

注意：**本地包含 token 与模型 key（600 root）**，异地包刻意不含（推 GitHub 会永久留痕）。

## 11. 新旧机逐项比对（2026-10-27 23:30 实测）

方法：两台机器跑同一份只读清单脚本 `deploy/parity-inventory.sh`（记录路径、权限、体积、版本、
env 键名，不含任何值），拉回本地做 diff。旧机 120 项、新机 102 项。

命令（本地 Windows，两台各跑一次再 diff）：

```powershell
scp -i $k deploy\parity-inventory.sh "root@<旧机>:/tmp/inv.sh"
ssh -i $k root@<旧机> 'bash /tmp/inv.sh' 2>$null | Out-File deploy\_old.txt
# 新机同前，输出 _new.txt，然后按「分区|键」比对
```

### 11.1 比对后补上的（真缺）

| 项 | 旧 | 新（补之前） | 处置 |
|---|---|---|---|
| 5 个手工运维脚本 | `/usr/local/bin/{check-task,recent-tasks,enqueue-owner-text.sh,seed-corrections.sh,preview-corrections.sh}` | 全缺 | **源码原本只存在于旧机**，已收回仓库 `deploy/bin/` 并纳入 `install-host-scripts.sh` 清单（8→13 项） |
| `pnpm` / `corepack` 四件套 | `/usr/local/bin/{pnpm,pn,pnpx,pnx}` | 全缺 | `npm i -g pnpm` 装到 12.15.0；`dsh plugin` 靠它转发，缺了只是插件管理不可用，不影响收发 |
| `/etc/dsh-qq-*` 目录权限 | `700` | `755` | `chmod 700`（里面有 token 与 key） |
| `/root/.dsh` 权限 | `700` | `755` | `chmod 700` |

### 11.2 判定为「不需要搬」的（有依据）

| 项 | 为什么不需要 |
|---|---|
| `/opt/node_modules/@deepseek-ai/dsh-tools` | 一个指向全局 dsh-tools 的软链。全机查 `NODE_PATH` **零引用**，两台的 `/usr/local/bin/dsh` 内容一致且都能跑 |
| `/opt/dsh-qq-bridge.old` / `node-plugin.old` / `node-plugin.prev` | 部署残留副本，每份 1 MB |
| `/etc/dsh-qq-bridge/env.bak.*` 三份 | 旧 token 快照；新 env 已含全部在用键 |
| `/root/.dsh/sessions`（8 MB）+ `attachments`（6 MB） | 她的**逐轮对话记录**没搬，长期记忆（`MEMORY.md` / `DIARY.md` / `CORRECTIONS.md`）全在 `/opt/dsh-qq-agent/persona` 已搬。搬过来会立刻让新会话复用最长 18 万 token 的历史，把成本拉回去；轮转阈值 60 轮也会很快把它截断 |

### 11.3 已知差异，不改

- **`linuxqq` 不再是 dpkg 包**：旧机 `dpkg -l linuxqq` = `3.2.34-53644`，新机查不到，QQ 是从旧机
  整目录拷过来的 `/opt/QQ`（614 MB）+ apt 补的 GTK3 依赖，跑得通（她在线）。代价是 `apt` 升级
  不会再动它，升级要手工换目录。**这条写在这里是为了下次换机别再以为是装坏了。**
- 新机独有（都是加固产物，属于改进）：`/etc/logrotate.d/dsh-qq`、`/etc/sysctl.d/99-dsh-qq.conf`、
  `/usr/local/bin/dsh-qq-post-migration-audit.sh`。
- 所有 `dsh-qq-*` 单元：旧机全部 `disabled`（迁移前停的），新机全部 `enabled`。


