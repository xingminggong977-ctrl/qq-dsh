# deploy/ 里的夜班脚本

两个脚本，都只跑在服务器（Ubuntu，root）上：

| 脚本 | 干什么 | 什么时候跑 |
|---|---|---|
| `install-nightly.sh` | 装/修/查/卸夜班的三个 systemd timer，建数据目录，做前置检查 | 首次部署、改单元、排障 |
| `apply-proposal.sh` | 把夜班产出的代码提案落地（备份→打补丁→跑全量测试→全绿才重启，否则回滚） | 白天人工审批某条提案时 |

契约见 [`docs/nightly-contract.md`](../docs/nightly-contract.md)：文件位置、硬上限、提案落地、时间表以那里为准。

**铁律：夜班进程自己永远不落盘代码。** 落地只走 `apply-proposal.sh`，且必须有同名 `.json`。

---

## 一、安装夜班：`install-nightly.sh`

```bash
install -m 0755 deploy/install-nightly.sh /usr/local/bin/install-nightly.sh   # 可选
/usr/local/bin/install-nightly.sh                 # 安装（幂等，重复跑没事）
/usr/local/bin/install-nightly.sh --status        # 只查状态，不改任何东西，不需要 root
/usr/local/bin/install-nightly.sh --uninstall     # 卸单元，产出全保留
/usr/local/bin/install-nightly.sh --user dshqq    # 夜班属主不是 root 时用（默认 root）
/usr/local/bin/install-nightly.sh --skip-token-check   # 夜班不用 bridge 的 NODE_TOKEN 时
```

安装按顺序做这些事（脚本里对应 `=== 0. 目标 ===` 到 `=== 8. 日志尾部 ===`；下面第 7 条合并了最后两节）：

1. **前置检查**：`node --version` 打得出来；`/opt/dsh-qq-agent/nightly/systemd/` 里至少有一个 `.timer`（契约要 3 个：03:00 挖矿 / 03:10 复盘 / 08:30 汇总，数量不符只警告不中断）；`/etc/dsh-qq-bridge/env` 里的 `NODE_TOKEN` **读到 / 没读到**（值永不打印，也不进日志）。
2. **目录与属主**：`/var/lib/dsh-qq-agent/nightly`（digest/stats/清单）、`/opt/dsh-qq-agent/proposals`、`/var/log/dsh-qq-nightly.log`（0640）。
3. **装单元**：把 `nightly/systemd/*.service`、`*.timer` 以 0644 root:root 装到 `/etc/systemd/system/`。
4. `systemctl daemon-reload`。
5. **enable --now 每个 timer**：已经 enabled/active 的只报状态不重做（幂等）。
6. 把装过的单元名写进 `/var/lib/dsh-qq-agent/nightly/installed-units.txt`——`--uninstall` 靠这份清单，也靠 `dsh-qq-nightly*` 兜底找漏网的。
7. 打印 `systemctl list-timers` 里匹配 nightly 的行（下次触发时刻）和日志尾部。

**卸载只拆单元**：`disable --now` + 删 `/etc/systemd/system/dsh-qq-nightly*`，digest、提案、日志一个都不删。真要清产出，手工来——`rm -rf` 不该藏在一条命令里。

### 怎么确认夜班真的在跑

```bash
# 1. 三个 timer 都装了、下次什么时候跑（TOTAL/LEFT/NEXT 三列最关键）
systemctl list-timers | grep nightly

# 2. 某次触发到底成没成（单元名按实际部署的写，下面按 digest 举例）
journalctl -u dsh-qq-nightly-digest -n 50 --no-pager

# 3. 夜班自己写的日志尾部
tail -n 50 /var/log/dsh-qq-nightly.log
```

按时间表核对产出，缺一个就是那一段没跑：

```bash
ls -lt /var/lib/dsh-qq-agent/nightly/ | head        # 03:00 之后应有 digest-YYYY-MM-DD.md + stats-YYYY-MM-DD.md
ls -lt /opt/dsh-qq-agent/proposals/ | head          # 03:10 之后应有 YYYY-MM-DD/ 目录
sudo -u root systemctl status dsh-qq-nightly-digest.timer --no-pager   # 看是不是 failed 后残留
```

判断口径：

- `list-timers` 里没有 nightly 行 → 单元没装或名字不匹配，跑 `install-nightly.sh --status`。
- timer 有、`journalctl` 里 03:00 没有任何记录 → `systemctl is-enabled` / `is-active` 看 timer 是否被关过；契约的关闭开关 `nightlyEnabled: false` 不发通知，别把它当故障。
- 有记录但没产出 → 看 `/var/log/dsh-qq-nightly.log` 尾部的拒绝原因（解析失败 = 整轮作废，这是设计，不重试）。

---

## 二、落地提案：`apply-proposal.sh`

```bash
# 预演：只在临时拷贝上打补丁 + 跑测试，不动线上、不重启、不备份
deploy/apply-proposal.sh /opt/dsh-qq-agent/proposals/2026-10-26/01-asr-stdout.patch --dry-run

# 真落地（会要人工确认）
deploy/apply-proposal.sh /opt/dsh-qq-agent/proposals/2026-10-26/01-asr-stdout.patch

# 无人值守（比如你自己已经在别处复核过）
deploy/apply-proposal.sh /opt/dsh-qq-agent/proposals/2026-10-26/01-asr-stdout.patch --yes

# 也可以给整个日期目录（目录里必须有且只有一个 .patch，否则拒绝）
deploy/apply-proposal.sh /opt/dsh-qq-agent/proposals/2026-10-26/ --dry-run
```

### 提案必须带同名 `.json`

```json
{
  "files": ["node-plugin/lib/asr.js"],
  "why": "失败原因只取了 stderr，stdout 的原因被丢掉",
  "created": "2026-10-26T03:10:00+08:00"
}
```

- `.json` 缺失或解析失败 → **退出码 2**，一个字节都不动。
- `files` 必须是非空字符串数组；它不是「提示」，是**准入清单**。

### 安全边界（本脚本唯一的准入判断）

`files` 里的每个路径，以及补丁正文 `--- / +++ / diff --git` 里的每个路径，都必须同时满足：

- 相对路径，落在 `node-plugin/` 或 `bridge/` 之下；
- 不含 `..`、`.`、空段、反斜杠、绝对路径；
- 规范化（`realpath -m`）之后仍在组件根之内；
- 一条提案只能碰一个组件（跨组件请拆成两条）。

出现 `../../etc/passwd`、`/etc/shadow`、`bridge/../../x` 这类东西 → **退出码 3，直接拒绝**，不做「尽力而为」的裁剪。补丁正文也验，因为只验 `.json` 会被「json 干净、diff 越界」绕过去。

### 落地流程

```
同名 .json 存在?
  └→ 校验 files + 补丁头路径 → 定组件（node-plugin → /opt/dsh-qq-agent/node-plugin，
                                      bridge      → /opt/dsh-qq-bridge）
     └→ 人工确认（没有 --yes 且非 tty → 直接拒绝）
        └→ 备份整个组件目录到 /var/backups/dsh-qq-proposals/<时间戳>-<slug>/
           └→ patch -p2（先 --dry-run 探一遍，打不上就回滚，不留 .rej）
              └→ 跑该组件全量测试（优先 npm test；没有就退回组件自带的固定命令）
                 ├→ 全绿 → 保留 + systemctl restart <服务> + 记录备份路径
                 └→ 失败 → 整目录回滚 + 退出码 4（测试） / 6（重启失败）
```

服务映射：`node-plugin` → `dsh-qq-agent`，`bridge` → `dsh-qq-bridge`。

测试命令（脚本里的回退值，与各组件 `package.json` 的 `test` 一致）：

- node-plugin：`node --import ./test/dsh-resolve.js --test test/index.js`
- bridge：`node --test test/*.test.js`

测试输出全文留在备份目录的 `test.log`，尾部 30 行贴到终端。

### 退出码

| 码 | 含义 | 线上状态 |
|---|---|---|
| 0 | 成功（或 dry-run 通过） | 已重启新代码 / 未改动 |
| 2 | 元数据缺失或坏（`.json`、`files`、JSON 语法） | 未改动 |
| 3 | 安全边界拒绝，或补丁打不上（上下文不符/已应用过） | 未改动或已回滚 |
| 4 | 测试没全绿 | 已回滚 |
| 5 | 用法/环境问题（缺 patch、缺 realpath、非 tty 没给 `--yes`、不是 root…） | 未改动 |
| 6 | 重启后服务起不来 | 已回滚，并再次重启回旧代码 |

### 回滚

**自动回滚**：测试或重启失败时脚本自己把组件目录整个换回备份，不需要人动手。日志里会有 `已回滚` 一行。

**手工回滚**（比如上线两天后才发现问题）：

```bash
ls -lt /var/backups/dsh-qq-proposals/            # 每次落地一个目录，名字是 <时间戳>-<slug>
B=/var/backups/dsh-qq-proposals/20261026-031512-01-asr-stdout

# 1. 先确认备份是完整的
ls "$B"                                          # 应有 node-plugin/（或 bridge/）+ patch + json + test.log

# 2. 停服务 → 换目录 → 起服务（顺序很重要：跑着的时候换文件会读到半新半旧）
systemctl stop dsh-qq-agent
rm -rf /opt/dsh-qq-agent/node-plugin
cp -a "$B/node-plugin" /opt/dsh-qq-agent/node-plugin
systemctl start dsh-qq-agent
systemctl is-active dsh-qq-agent

# 3. 确认回到旧行为
journalctl -u dsh-qq-agent -n 50 --no-pager
```

别用 `git checkout` 之类的东西回滚：这台机器上的组件目录不一定是 git 仓库，备份才是唯一事实。

### 审计日志

每次动作（校验通过/拒绝、备份路径、补丁应用、测试结果、保留/回滚、重启结果）都追加到：

```
/var/log/dsh-qq-proposal.log
```

行首是 ISO 时间戳，可以直接 `tail -f` 看着跑。日志里**没有** token、没有环境变量值。

---

## 三、在本机预演（不碰服务器）

两个脚本都有同一个测试钩子：**只有同时设 `DSH_QQ_TEST_ROOTS=1`**，才允许用自己的路径覆盖常量。单个环境变量改不动线上路径，这是故意的。

```bash
export DSH_QQ_TEST_ROOTS=1
export DSH_QQ_AGENT_ROOT=/tmp/fake-qq/agent      # 指向假仓库
export DSH_QQ_BRIDGE_ROOT=/tmp/fake-qq/bridge
export DSH_QQ_PROPOSAL_LOG=/tmp/fake-qq/proposal.log
export DSH_QQ_BACKUP_ROOT=/tmp/fake-qq/backups
deploy/apply-proposal.sh /tmp/proposal-test/01-demo.patch --dry-run --yes
```

`install-nightly.sh` 同样的门，另外可用 `DSH_QQ_SYSTEMCTL` 指向一个假的 `systemctl` 来预演 enable/start 流程；预演模式下脚本会跳过 root 检查和 `chown`。

**预演模式会在输出第一行大字说明自己开着。** 生产机上不该存在 `DSH_QQ_TEST_ROOTS`。

---

## 四、写这两个脚本时没能验证的假设

写在明面上，免得后来人当成已确认的事实：

1. **单元文件名**。`nightly/systemd/` 里到底叫 `dsh-qq-nightly-digest.timer` 还是别的，本机没有这个目录，脚本一律「发现 + 全装」，不硬编码名字；只有卸载兜底时假设前缀是 `dsh-qq-nightly`（清单文件优先）。
2. **单元里的 `User=`**。夜班进程以 root 跑是我的推断（`dsh-qq-agent` 的 profile 在 `/root/.dsh`，节点插件由它以 root 身份拉起）。若单元写的是 `User=dshqq`，要 `--user dshqq`，否则夜里写 `/var/lib/.../nightly` 会 Permission denied；脚本在 `--user` 非 root 时会比对单元里的 `User=` 并告警，但它没法替你决定用哪个。
3. **`NODE_TOKEN` 的用途**。脚本只确认「能从 `/etc/dsh-qq-bridge/env` 读到」，没有验证夜班的挖矿器真的用这个名字做鉴权（契约没写这一节）。
4. **dry-run 的测试环境**。`--dry-run` 把组件目录拷到 `mktemp -d` 后跑测试；如果某组测试依赖「组件父目录」里的东西（例如 `node_modules` 只装在父级），dry-run 可能红而真落地是绿的。失败时临时目录会保留并打印路径，先看 `test.log` 再判断。
5. **`patch` / `realpath` 的版本**。脚本要求 `patch`（GNU，`--dry-run --reject-file=-`）和 `realpath`（coreutils）存在，缺失时退出码 5 并提示 `apt install`。Debian/Ubuntu 默认都有，但没有在服务器上实测过。
6. **`npm test` 是否总是存在**。脚本优先 `npm test`，`package.json` 没有 `test` 脚本或机器上没有 `npm` 时退回固定命令；两条路都没在服务器上跑过。

---

## 五、主机脚本的版本化

### 为什么必须进仓库

2026-10-26 盘点发现一件很险的事：`/usr/local/bin/` 下 4 个主机脚本**长期只存在于服务器**，
仓库里的同名副本已经过期——`deploy/dsh-qq-healthcheck.sh` 是 3896 字节的旧版，
而线上 `/usr/local/bin/dsh-qq-healthcheck.sh` 是 5283 字节（10-26 09:50 改过，多了宽限期、
两轮确认、告警恢复去抖三段逻辑）。**拿仓库里的版本覆盖线上，会静默退化成没有防误报的旧巡检。**

更糟的是 `dsh-qq-backup.sh` 自己也不备份 `/usr/local/bin`（见下一节），
也就是说**这台机器一旦坏掉，这 4 个脚本没有任何副本可恢复**。

所以现在把线上原文取回仓库，`deploy/bin/` 成为权威副本：

| 仓库路径 | 对应线上路径 | 来源 |
|---|---|---|
| `deploy/bin/healthcheck.sh` | `/usr/local/bin/dsh-qq-healthcheck.sh` | 线上原文 + 补齐 2 个服务巡检 |
| `deploy/bin/backup.sh` | `/usr/local/bin/dsh-qq-backup.sh` | 线上原文逐字取回，未改动 |
| `deploy/bin/alert.mjs` | `/usr/local/bin/dsh-qq-alert.mjs` | 线上原文逐字取回，未改动 |
| `deploy/bin/napcat-watch.sh` | `/usr/local/bin/dsh-qq-napcat-watch.sh` | 2026-10-26 新写：QQ 内核僵死看门狗 |
| `deploy/bin/backup.sh.gaps.md` | —（说明文档，不安装） | 备份覆盖缺口清单 |

### 内核僵死看门狗（`napcat-watch.sh` + `dsh-qq-napcat-watch.timer`）

2026-10-26 当天 QQ 内核僵死了两次（11:23、22:46，间隔约 11 小时），症状是
`EventChecker Failed: NTEvent serviceAndMethod:NodeIKernelMsgService/sendMsg`：
NapCat 报告自己在线，但任何消息都投不出去（`retcode 1200`），入站也会一起停。
主人看到的现象就是「她不理我」，而 `get_status` 里 `online: true` 全是假的。

`dsh-qq-napcat-watch.timer` 每 3 分钟跑一次，把「重启」与「复核」拆成两次运行，
单次运行不超过 60 秒：

| 阶段 | 动作 |
|---|---|
| 检测 | 近 10 分钟 `EventChecker Failed` ≥ 3 次即判定僵死 |
| 三道闸 | 30 分钟冷却；登录流程进行中（等扫码 / 快速登录中）绝不重启；napcat 非 active 时交给 systemd |
| 复核 | 重启后真发一条私聊，发得出去才算恢复 |
| 兜底 | 3 分钟内仍发不出去 → 微信推送（`push-notify.sh`），因为这时 QQ 本身就是坏的 |

「登录流程进行中不重启」这条是拿事故换来的：2026-10-26 22:51 主人扫码成功，
22:53 我自己的重生成二维码脚本又把 NapCat 重启了一次，把那次登录打断了。
重启前必须先读日志确认。

验证记录（2026-10-26 23:05）：默认窗口下安静无动作；把窗口放宽到 14 小时、阈值 1
时正确判定「840 分钟内 9 次 EventChecker Failed」并被 `DRY_RUN=1` 拦在重启之前；
手工伪造 `restart-at` 后复核分支真的发出消息并自清状态。

`healthcheck.sh` 相对线上唯一的功能改动：服务巡检从 3 个补到 5 个——

```diff
-for svc in napcat dsh-qq-bridge dsh-qq-agent; do
+for svc in napcat dsh-qq-bridge dsh-qq-agent dsh-qq-crisis dsh-qq-friend; do
```

`dsh-qq-crisis`（危机词监控）和 `dsh-qq-friend`（自动加好友）原来完全没被巡检覆盖。
它们挂掉**没有任何外部症状**：QQ 照常收发，只是危机词不再触发、好友申请不再自动通过。
这正是健康巡检该兜住的那类静默失效。宽限期、两轮确认、告警渠道等原有逻辑一行未动。

### 怎么装回去

```bash
bash deploy/install-host-scripts.sh --dry-run   # 默认就是 dry-run，只打印
sudo bash deploy/install-host-scripts.sh --apply
```

安装器做的事：先 `bash -n` / `node --check` 验语法（**验不过就不装**），
再逐文件比对 sha256（一致则跳过，所以可反复跑），不同则先备份旧版再 `install -m 0755 -o root -g root`。

**不需要重启任何服务**：`dsh-qq-healthcheck.timer` 每轮直接执行该文件，下一轮就吃到新版本。

### 备份放哪儿（这条和 `check-host.sh` 有关系）

旧版备份落在 `/usr/local/bin/` 里，留下过 `/usr/local/bin/dsh-qq-healthcheck.sh.bak-20261026-095001`。
而 `check-host.sh` **第 6 项就是检查 bin 目录里 `.bak` 残留必须为 0**，`harden-host.sh` 第 6 步专门清它。

所以安装器把备份改放到 `/var/backups/dsh-qq-bin/<name>.bak-<时间戳>`。
**如果放回 bin 目录，每次安装都会把自检搞红，等于自己制造自己要去清理的残留。**

### 备份脚本的覆盖缺口

`deploy/bin/backup.sh` 只打包 6 条路径（agent 三个目录 + profile 两个文件 + DSH 凭证），
**`/var/lib/dsh-qq-bridge/` 这个唯一的业务数据目录完全没备**——其中 `queue.db-wal` 有 3.4MB、
比 `queue.db` 本身大 10.7 倍，只搬 `queue.db` 会丢数据。

还有一条比"漏路径"更危险的：`tar` 那行是 `2>/dev/null || true`，
成功判据只有「产物非空」，所以**任意一条路径读不到时备份依然报告成功，只是悄悄少了那部分**。

完整缺口清单、真实路径、按体积权衡过的扩展建议，见
[`bin/backup.sh.gaps.md`](bin/backup.sh.gaps.md)。修不修是另一个决定，那里只摆事实。

### 和主机加固的关系

三套东西职责不同，别混：

| 脚本 | 管什么 | 什么时候跑 |
|---|---|---|
| `harden-host.sh` | swap / swappiness / sqlite3 / journald 上限 / logrotate / `.bak` 清理 | 新机首次，或改了加固参数 |
| `check-host.sh` | 11 项只读自检，有 FAIL 就 exit 1 | 加固后、换机后、日常巡检 |
| `install-host-scripts.sh` | 把 `deploy/bin/` 装到 `/usr/local/bin/` | 改了 `deploy/bin/` 里的脚本之后 |

`harden-host.sh` 和 `install-host-scripts.sh` 都默认 dry-run，要动手必须显式 `--apply`。

## 六、换机第一步：`init-new-host.sh`

`migrate-export.sh` / `migrate-restore.sh` 这一对只搬**服务自己的东西**：代码、配置、凭据、unit、数据库、profile。
它们默认新机上已经有 `dshqq` 这个用户、有 `/usr/local/bin/node` 24、有 xvfb 和整套 Electron 运行库、
有 `/opt/asr-venv`、journald 有上限、时区是 CST。

这些以前靠人脑记。漏一条的现场特别难认：还原跑完 8 步全绿、59 项自检也过，
然后 `systemctl start dsh-qq-bridge` 死在 `node: not found`；或者 QQ 在 xvfb 里起不来，
只报一句 `Missing X server or $DISPLAY` —— 离真实原因还隔着好几层。

`init-new-host.sh` 就是把这段「说不清、但漏了就起不来」的系统底子钉死，位置在 `migrate-restore.sh` **之前**。

### 用法和其它 host 脚本一致

```bash
bash init-new-host.sh --dry-run     # 默认：只打印，一个字节都不改
sudo bash init-new-host.sh --apply  # 真正落地；root 只在 --apply 时要求
```

幂等：每一步先看现状，齐了就打印 `已就绪，跳过`。全都装好了就完全不调 apt，
venv 里版本对了就不碰 pip —— **所以它可以反复跑，也可以在一台半好的机器上跑**。

### 九步各管什么

| 步 | 动作 | 为什么必须是它先做 |
|---|---|---|
| 0 | 前置检查：Linux / Ubuntu 22.04 / x86_64 / root（仅 `--apply`）/ 内存 ≥ 3500MB / 根分区 ≥ 15G | 这几条任一不满足，后面九步全是白跑；1G/2G 内存的机器不是「慢一点」，是 OOM |
| 1 | 时区 `Asia/Shanghai` + `systemd-timesyncd` | 时区错会让 3 条夜班 cron 在错的小时触发；时钟漂移会让 token 与会话签名失效 |
| 2 | apt 基础包 12 个 + QQ 运行库 19 个 | 分两个数组：基础包（ffmpeg / sqlite3 / xvfb / python3-venv）和 QQ 那 19 个库的失败原因完全不同，缺哪个就报哪个名字 |
| 3 | Node 24 → `/usr/local/bin/node` | bridge 的 unit 里 `ExecStart` 写死了这个路径，见下一节 |
| 4 | 系统用户 `dshqq` | 旧机 uid/gid 都是 998，业务文件全归它；后面 15 个目录的属主要靠这个用户存在 |
| 5 | 15 个目录 + 属主 + 权限 | 还原包 tar 里是相对路径、解到 `/`；目录不存在，解出来就是散落一地的文件。属主分 `root:root` 与 `dshqq:dshqq` 两档，和 `migrate-restore.sh` 第 3 步的判定一致 |
| 6 | `/opt/asr-venv` + `faster-whisper==1.0.3` | ASR 是唯一要现装的东西（要 wheels，不是 apt 包）。钉 1.0.3 是与旧机对齐，换版本等于换掉 ctranslate2 大版本，转录结果会跟着变 |
| 7 | journald 上限 + `vm.swappiness=10` | 各写一个独立 drop-in 文件而不是改主配置：将来回退，删文件就行 |
| 8 | 只检查不搬运：`/opt/asr-models`、`/opt/QQ`、`/opt/napcat` 本体 | 这三样加起来 1.3G，**根本不在还原包里**，见下面那一节 |
| 9 | 还缺什么 / Go-No-Go 结论 | 把缺的目录、凭据、unit 三张清单摆在一起，最后给一句能不能开跑。没有这句结论，人就会在还缺东西时去还原，然后在一屏绿字里找那一条红 |

### 为什么 Node 用官方 tarball 而不是 NodeSource

两条路都能用，选官方 tarball（`registry.npmmirror.com/-/binary/node/v24.22.1/`），三条理由：

1. **路径对**。NodeSource 装出来落在 `/usr/bin/node`，而 `dsh-qq-bridge.service` 的
   `ExecStart=/usr/local/bin/node ...`、`migrate-verify.sh` 的 `ls -l /usr/local/bin/node` 都盯着
   `/usr/local/bin`。用 apt 装完还得补一层软链，不如一步到位。
2. **版本能钉死**。旧机是 v24.22.1，tarball 能钉这个数字；NodeSource 的 `node_24.x` 只保证大版本，
   小版本哪天一跳，新机就和旧机不是同一个 runtime。**换机时最不该引入的变量就是「顺手升了个小版本」。**
3. **少一个第三方 keyring**。NodeSource 要往 `/usr/share/keyrings` 塞它自己的 GPG key；
   tarball 只验 Node 官方 `SHASUMS256.txt` 里的 sha256 —— 校验不过直接 `die`，不给「先装上再修」的机会。

被否掉的那条路留在这儿，省得下次有人重查：

```bash
echo 'deb https://deb.nodesource.com/node_24.x nodistro main' > /etc/apt/sources.list.d/nodesource.list
```

落点：解到 `/usr/local/lib/nodejs/node-v24.22.1-linux-x64/`，再把 `bin/*` 逐个软链到 `/usr/local/bin`
（Node 24 可能不再带 `corepack`，所以按 `bin/*` 遍历，不写死那几个名字）。
装完必须 `node -v` 主版本 ≥ 24，第 3 步结尾会把实际版本打出来。

### 为什么还是先试 998

`migrate-restore.sh` 自己写了：`新机 uid=NNN ≠ 旧机 998 —— 不影响，后面一律按用户名 chown`。
所以 998 **不是正确性要求**，本脚本发现被占用就退到系统默认分配。

那为什么还试？因为解包用 tar 默认的名字映射，uid 一致时 `ls -l` 出来的东西一眼就对得上；
对不上时排查「这个文件该归谁」要翻半天。能对上就对上，对不上照样能跑 ——
第 4 步会把实际 uid/gid 打印出来，后面所有 `chown` 一律按用户名。

### 第 8 步只检查不搬运：这三样不在还原包里

任务书里说 `/opt/asr-models`、`/opt/QQ`、`/opt/napcat` 由 `migrate-restore.sh` 还原。
**读 `migrate-export.sh:404-408` 得到的结论相反**：

```
# 明确排除（不在包里）:
#   /opt/QQ /opt/napcat/napcat（程序本体，新机官方脚本重装）
#   /opt/asr-venv /opt/asr-models（可重建）
```

包里只有 `/opt/napcat/launcher.sh` 和 `/opt/napcat/napcat/config` 这两小份。
`migrate-restore.sh` 第 6/8 步对 `/opt/QQ`、`/opt/napcat/napcat`、`/opt/asr-venv` 的措辞也是
`还没有装 —— 先用官方脚本重装，否则服务起不来`。

所以这三样只检查、只报缺：

| 目录 | 旧机体积 | 里面该有什么 |
|---|---|---|
| `/opt/asr-models` | 约 464MB | `models--Systran--faster-whisper-small`（含 CTranslate2 转换产物） |
| `/opt/QQ` | 约 614MB | QQ NT 客户端本体（官方安装包装的） |
| `/opt/napcat` | 约 238MB | `launcher.sh`、`cache`、`config`（本体不在包里） |

缺了二选一：从旧机 `rsync -aP` 过来，或用官方脚本重装。
**本脚本不联网下载**：QQ / NapCat 的官方地址会变，模型要走 HF 镜像，
把这三件自动化，等于把还原过程变成一场不可复现的下载。

### 它明确不做的事

写进了文件头注释，防止以后有人顺手加：

- 不开任何公网端口（安全组、ufw 都不碰）
- 不改 `sshd`（改它会把还连着的会话踢下去，且加固脚本也没碰）
- 不写任何凭据文件（`/etc/dsh-qq-*/env` 一律由还原包带过来，600 root:root）
- 不创建 systemd unit（13 个单元全在还原包里；本脚本只数一下现在有几个）
- 不下载 QQ / NapCat / 模型
- 不建 swap 文件、不动 logrotate、不清 `.bak` 残留 —— 那是 `harden-host.sh --apply` 的活

有一处刻意重叠：swappiness 两个脚本都写（本脚本 `/etc/sysctl.d/60-dsh-qq.conf`，
加固脚本 `/etc/sysctl.d/99-dsh-qq.conf`），值都是 10。`sysctl.d` 按文件名字典序生效，
99 那个排在后面覆盖前面 —— 值一样所以不打架，但要知道有**两个**文件写着这个数。

### 怎么验（本机只能验语法）

```bash
bash -n deploy/init-new-host.sh        # 语法；Git Bash 里就这么跑
bash deploy/init-new-host.sh --dry-run # 会停在前置检查：MINGW64 不是 Linux，exit 1
```

在 Windows 上 dry-run 停在「不是 Linux」是**对的**：它说明前置检查在工作，
而不是撞死在某个语法错误上、也不是假装改过系统。真正的前置检查只有在 Linux 上跑才算数。
