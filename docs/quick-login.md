# NapCat / QQ 快速登录（免扫码重启）

**一句话结论**：快速登录 = `launcher.sh` 里的 `-q 10002` 参数（决定"登哪个号"）**+** 磁盘上仍然有效的 QQ 登录凭据（决定"能不能免密"）。少了 `-q`，即使凭据在，重启也会落到二维码 —— 这正是本机两次重启都要扫码的直接原因。

本文所有"实测"均来自对线上 `root@203.0.113.11` 的**只读** ssh 采集（`ls` / `cat` / `systemctl cat` / `journalctl`），未对线上做任何写操作。

---

## 1. 快速登录靠什么成立

### 1.1 结论：加 `-q <QQ号>`，不是改配置文件

改的是 `/opt/napcat/launcher.sh` 第 4 行：

```diff
-exec xvfb-run -a env LD_PRELOAD=./libnapcat_launcher.so /opt/QQ/qq --no-sandbox "$@"
+exec xvfb-run -a env LD_PRELOAD=./libnapcat_launcher.so /opt/QQ/qq --no-sandbox -q 10002 "$@"
```

### 1.2 为什么是命令行参数而不是配置字段

NapCat 有**两套**配置，两套里都没有自动登录字段，这是排除了配置路径的直接证据：

| 文件 | 全文出现的键 | 有快速登录字段吗 |
|---|---|---|
| `/opt/napcat/napcat/config/napcat.json` | `fileLog` `consoleLog` `fileLogLevel` `consoleLogLevel` `packetBackend` `packetServer` `o3HookMode` `bypass{hook,window,module,process,container,js}` | 否 |
| `/opt/napcat/napcat/config/napcat_10002.json` | 同上 + `autoTimeSync` | 否 |
| `/opt/napcat/napcat/config/napcat_protocol_10002.json` | `{"enable": false, "network": {"httpServers": [], "websocketServers": [], "websocketClients": []}}` | 否（只是协议开关） |

### 1.3 依据出处（三条，互相独立）

**（a）官方文档** <https://napneko.github.io/guide/boot/Shell> 正文原文：

> 没有 FUSE 时添加 `--appimage-extract-and-run`。**快速登录添加 `-q 123456789`**。保持启动目录固定，更新时保留其中的数据。

**（b）NapCat 发行包自带的官方示例脚本**（就在本机 `/opt/napcat/napcat/` 下，不依赖网络）：

`/opt/napcat/napcat/quickLoginExample.bat`：
```
REM 快速登录示例脚本
REM -q 参数是可选的，不传则使用二维码登录
REM ./launcher-user.bat 123456
```

`/opt/napcat/napcat/launcher-win10-user.bat`：
```
REM Optional: -q <QQ_NUMBER> for quick login, omit for QR code login
REM Example: "%NAPCAT_LAUNCHER_PATH%" "%QQPath%" "%NAPCAT_INJECT_PATH%" -q 123456
```

两个 `.bat` 结尾都调用 `"%NAPCAT_LAUNCHER_PATH%" "%QQPath%" "%NAPCAT_INJECT_PATH%" %*`，与 Linux 版 `launcher.sh` 的 `"$@"` 是同一个透传结构。

**（c）参数确实能送到 QQ**（这是"加了却没用"最常见的翻车点，已验证）：

- `/opt/QQ/qq` 是 ELF 二进制可执行文件（`file` 确认），不是 shell 包装脚本，参数直达 QQ 主进程。
- `/opt/napcat/launcher.cpp` 源码里只有 LD_PRELOAD 注入逻辑（常量 `TARGET_PACKAGE_JSON="resources/app/package.json"`、`TARGET_NAPCAT_JS="resources/app/loadNapCat.js"`），**全文无 argv/argc 处理** —— 即启动器不吞参数。
- `launcher.sh` 末行 `"$@"` 原样透传。而 `ExecStart=/bin/bash /opt/napcat/launcher.sh`（**不带任何参数**），所以 `-q` 必须写进 `launcher.sh` 里，不能指望 unit 传参。

### 1.4 `-q` 单独够不够？——必要但不充分

`-q` 是"选择账号"的开关，不是"生成凭据"的开关。凭据来自磁盘（见 §2）。

- **有票无 `-q`**：本机实测旁证 —— `/root/.config/QQ/` 下明明躺着 `login.db` 与账号目录，一天内两次 `systemctl restart napcat` 仍然落到二维码（`deploy/` 目录里 `qrcode-113254.png`、`qrcode-113552.png`、`qrcode-134809.png` 等截图即当时留存）。说明票据存在并不自动触发免扫码。
- **有 `-q` 无票**：官方示例注释已写明"不传则使用二维码登录"的反面，即传了 `-q` 才走快速登录；无票据时客户端会回落到二维码（这正是新机器上可能仍要扫一次的机理，见 §5）。

**所以完整链条是**：`-q`（选账号）+ 有效票据（免密）+ 票据里的设备指纹能被服务端接受（跨机的不确定项）。

---

## 2. QQ 登录态实际落在哪些路径（实测）

### 2.1 目录总览（`ls -la` 原文，已裁剪）

```
/root/.config/QQ/                                          drwx------  225M
├── crash_files/                     drwxr-x---      空
├── Crashpad/                        drwx------      client_id
├── global/                          drwxr-xr-x      162M   ← 全局票据，必带
│   ├── nt_data/
│   │   ├── Login/.10002        -rw-r--r--      0 字节  ← "上次登录的账号"
│   │   ├── msf/machine-info         -rw-------      21 字节 ← 设备指纹，必带
│   │   ├── msf/msfconnseq           -rw-------      9 字节
│   │   ├── msf/msfsecuritysign_type -rw-------      5 字节
│   │   ├── msf/msfnethistory_155ffdc80c9a9b08ca2f6cc91ebe6412  -rw------- 5541 字节
│   │   ├── msf/security_data/       drwx------      空
│   │   ├── mmkv/                    mmkv.default(.crc) / nt_mmkv_global_misc(.crc)
│   │   │                            nt_mmkv_msf_united_config(.crc) / nt_mmkv_united_config_no_login_v3(.crc) / nt_mmkv_o3(.crc)
│   │   └── Skin/ Log/
│   ├── nt_db/login.db               -rw-r--r--      5120 字节   ← 加密登录票据，必带
│   ├── nt_db/login.db-wal           -rw-r--r--     86552 字节   ← 必带（未落盘的事务）
│   ├── nt_db/login.db-shm           -rw-r--r--     32768 字节
│   └── nt_temp/nt_db/
├── NapCat/{data,temp}/                               ← NapCat 自己的运行时目录
└── nt_qq_2bfee1e17135a558f4d38470a7bc6200/           drwxr-xr-x  63M  ← 账号级数据
    ├── nt_data/{msf/security_data,Ptt,Pic,File,Video,Emoji,avatar,mmkv,…}
    ├── nt_db/  (57+ 个 sqlite：nt_msg.db 1152KB、profile_info.db、misc.db、
    │            group_info.db、buddy_msg_fts.db、emoji.db、settings.db、
    │            collection.db、guild1.db、yffm.db、rdelivery.db、recent_contact.db …)
    └── nt_temp/
```

`machine-info` 内容实测（`cat` 原文，前导空格保留）：

```
  00-16-3r-5r-nr-8r
```

这是腾讯客户端生成的**伪 MAC 设备指纹**（`3r`/`5r`/`nr` 是非十六进制占位符，说明它是派生值而非真网卡地址），21 字节。

### 2.2 没有 keychain

```
$ ls -la /root/.local/share/keyrings/
ls: cannot access '/root/.local/share/keyrings/': No such file or directory
```

`/root/.config/keyring*` 同样不存在。headless root 无 gnome-keyring / libsecret 服务，**凭据 100% 落在上面这棵文件树里**，没有额外的东西要从密钥环导出。

### 2.3 迁移时带什么、不带什么

| 路径 | 带? | 理由 |
|---|---|---|
| `/root/.config/QQ/global/nt_db/login.db{,-wal,-shm}` | **必须** | 登录票据本体，三件套一起拷（`-wal` 里有未 checkpoint 的数据，只拷主库会读到旧快照） |
| `/root/.config/QQ/global/nt_data/msf/machine-info` | **必须** | 设备指纹。少了它，新机自己生成一个，票据立刻对不上 |
| `/root/.config/QQ/global/nt_data/Login/.10002` | 建议 | "上次登录账号"标记，0 字节，与 `-q` 配合指向同一账号 |
| `/root/.config/QQ/global/nt_data/mmkv/*` | 建议 | 全局配置缓存，含登录相关状态 |
| `/root/.config/QQ/nt_qq_2bfee1e17135a558f4d38470a7bc6200/` | **必须整目录** | 账号级数据。目录名是客户端派生的哈希，**不是** `md5(uin)`（实测 `md5("10002") = edfae2cddf0deca322f480e412424769`，与 `2bfee1e17135a558f4d38470a7bc6200` 不符），无法在新机推算，只能整目录复制 |
| `/root/.config/QQ/{crash_files,Crashpad,Log,nt_temp}` | 可不带 | 崩溃转储/临时文件，无登录价值 |
| `/opt/napcat/napcat/config/` | **必须** | 含 `onebot11_10002.json`（WS 服务与 token）、`webui.json`、`passkey.json` |
| `/opt/napcat/` 其余（`launcher.sh`、`libnapcat_launcher.so`、`install.sh`、`napcat/`） | **必须** | 由新机重装更稳，见 §3 |
| `/etc/dsh-qq-agent/env` | 待 Lead 核实 | `deploy/fix-restart-napcat.sh` 从这里读 `NAPCAT_ACCESS_TOKEN`，若 token 不写在 `onebot11_*.json` 里，漏了它 bridge 连不上 |

---

## 3. 迁移顺序（尽量不触发风控）

历史教训：一天内两次重启都要求扫码，**其中一次扫码后账号被风控（ErrCode 168）**。所以顺序的设计目标是"减少扫码次数 + 避免新旧机同时在线互相顶号"。

### 3.1 推荐顺序

```
① 新机装环境（不启动服务）
   - 装 QQ（对齐 /opt/napcat/napcat/qqnt.json: version 9.9.22-40990 / linuxVersion 3.2.20-40990）
   - 装 NapCat，部署 /opt/napcat/{launcher.sh,libnapcat_launcher.so,loadNapCat.js} 与 systemd unit
   - 此时【不要 systemctl start napcat】
② 先配快速登录开关（趁服务没起，改文件不影响任何在线会话）
   - bash deploy/enable-quick-login.sh --dry-run   # 看 diff
   - bash deploy/enable-quick-login.sh --apply     # 写入 -q 10002
③ 带登录态（旧机【已停】的前提下）
   - rsync -a /root/.config/QQ/         新机:/root/.config/QQ/
   - rsync -a /opt/napcat/napcat/config/ 新机:/opt/napcat/napcat/config/
   - 权限照抄：/root/.config/QQ 必须 700，msf/ 下文件 600（rsync -a 会保留）
④ 旧机停服务
   - systemctl stop napcat && systemctl disable napcat
   - 这一步必须在启动新机之前完成：同一个 QQ 号不能双端在线，否则互相顶号 = 风控触点
⑤ 启动新机，一次性观察
   - systemctl start napcat
   - journalctl -u napcat -n 100 --no-pager    # 有二维码/扫码提示 = 没免成
⑥ 分情况处置
   - 没弹二维码 → 成功。执行 §6 验收
   - 弹了二维码 → 扫【这一次】，扫完立即验证：再 systemctl restart napcat 一次，确认这次不再要扫码
```

### 3.2 顺序里几个不能反的点

- **② 早于 ⑤**：`-q` 必须在第一次启动前就位，否则第一次启动就落二维码，白扫一次。
- **③ 的时效**：票据有有效期，拷贝和启动之间越短越好；不要先拷完放一晚上再启动。
- **④ 早于 ⑤**：旧机不停就起新机，等于同号双端，这是 168 最常见的触发器。
- **拷贝期间旧机不停也可以**：只读 rsync 不改变旧机状态；但要接受 `login.db-wal` 可能正在写，所以三件套（`.db` + `-wal` + `-shm`）必须一起取，不要只拿主库。
- **不要反复重启试探**：每重启一次都是客户端向服务端重新握手；扫完码后的第一次重启验证通过就够了，别连着重启三次。

---

## 4. 回滚与止损

### 4.1 改坏了怎么回滚

```bash
# 只看还原 diff，不写盘
bash deploy/enable-quick-login.sh --rollback --dry-run

# 实际还原：用最近一份 launcher.sh.bak-<时间戳> 覆盖回来
bash deploy/enable-quick-login.sh --rollback
```

脚本行为：
- 备份命名 `<文件>.bak-<YYYYmmdd-HHMMSS>`，用文件名排序取**最近一份**。
- 还原前会**再快照一份** `.bak-pre-rollback-<时间戳>`，所以"回滚"本身也可回滚。
- 找不到任何备份时直接报错退出，不会瞎猜。

手工回滚（脚本不可用时）：

```bash
ls -1 /opt/napcat/launcher.sh.bak-*        # 挑最近一份
cp -p /opt/napcat/launcher.sh.bak-20261026-223059 /opt/napcat/launcher.sh
systemctl restart napcat
```

### 4.2 加了 `-q` 之后反而起不来

症状与处置：

| 症状 | 判断 | 处置 |
|---|---|---|
| 服务起但 QQ 立刻退出，日志无登录迹象 | `-q` 位置写错 / 被当成 QQ 的参数解析失败 | `--rollback` → 核对 §1.1 的 diff 行，确认 `-q` 在 `--no-sandbox` 之后、`"$@"` 之前 |
| 反复重启，`Restart=always` 每 10s 抖一次 | 账号在别处在线 | 先确认没有第二个实例（旧机/本地调试）在跑同一 QQ 号，再考虑回滚 |
| 出现二维码 | `-q` 生效了但票据缺失/失效 | 不需要回滚。扫一次码，然后 §6 验证 |

### 4.3 `--apply` 的安全边界

- 只改 `launcher.sh` 一行，不碰 systemd unit、不碰 NapCat 配置、不碰 `~/.config/QQ`。
- 写入走 `mktemp` + `bash -n` 语法校验 + `mv` 原子替换，语法错就不写。
- 用 `chmod --reference` 保留原权限位，避免 `launcher.sh` 丢掉可执行位。
- **脚本永不重启服务**，只打印提示。重启是人的决定。

### 4.4 止损：新机带过去仍然要扫码

按伤害从小到大：

1. **扫这一次**（推荐）。扫码后立刻按 §6 验收快速登录，验收通过后这个号以后的重启就不用再扫了 —— 隐患已经拔掉，只是多花一次扫码。
2. **扫不出来（二维码加载失败/超时）** → 不要连续重试。停新机服务，回旧机（旧机原样未动，回切成本最低），改天再做。
3. **扫了但报 ErrCode 168** → 立刻停手。这是风控，继续试只会加重。等 24h+ 再试，并且这次要同时满足：出口 IP 与旧机一致、机器指纹（`machine-info`）已带过去、旧机确已下线。
4. **彻底放弃跨机带登录态** → 新机上当作全新机器，扫一次码，然后 `enable-quick-login.sh --apply` 配好 `-q`。这台机器以后的重启不再扫码（隐患照样解决），代价是一次人工扫码。

---

## 5. 已知限制：跨机器免扫码不可靠

### 5.1 `-q` 能跨机器生效吗？

**不能直接跨机器生效。** `-q` 不生成任何凭据，它只是"告诉 QQ 登哪个号"。真正决定免不免密的是磁盘上的票据（§2），而票据和**设备指纹**绑在一起：

- 票据密文在 `global/nt_db/login.db`（SQLite，`strings` 可见 `QQ_NT DB#`、`HMAC_SHA1(` 字样）。
- 指纹在 `global/nt_data/msf/machine-info`，是客户端派生的伪 MAC。
- 两者在**同一棵树**里，且 `msf/` 目录下还有 `msfconnseq`、`msfsecuritysign_type`、`msfnethistory_*` 一起参与握手。

把整棵树原样搬过去，**指纹也一起搬过去了**，这是唯一有机会免扫码的做法；但即便如此也不保证：服务端还会看出口 IP、登录时间、历史行为，票据本身也可能过期。**跨机器免扫码不可靠，不能写进 SLA。**

### 5.2 因此的替代方案（推荐照此执行）

> **迁移窗口内接受"一次扫码"，把"以后每次重启不再扫码"作为真正的交付目标。**

理由：本任务的痛点是"**每次**重启都要人工扫码"（崩溃恢复必须有人在场、迁移窗口更被动），不是"这次迁移要不要扫码"。配好 `-q` 之后，即使在新机上扫了那一次，后续所有重启（含崩溃自动拉起）都走快速登录，痛点消除。扫码次数从"每次重启一次"降到"一台机器一次性"。

### 5.3 附带限制

- **一个 QQ 号只能一端在线**。新旧机同时跑会互相顶号，这本身就是风控触发器（历史 ErrCode 168 的教训）。
- **`Restart=always` + `RestartSec=10`**：如果 `-q` 配置有误导致启动即崩，会变成每 10 秒一次的重启风暴，比扫码更伤账号。上线前务必先 `--dry-run` 确认 diff。
- **NapCat 升级可能覆盖 `launcher.sh`**（官方文档明确要求"保持启动目录固定，更新时保留其中的数据"）。升级后重跑一次 `--dry-run` 检查 `-q` 是否还在。
- **无 keychain 是好事**：headless 环境凭据全在文件里，迁移只要搬文件；反过来说，文件搬漏一样就免不了密。

---

## 6. 验收清单（暗伤 1 的最终验收）

改完必须重启才生效 —— **重启由人执行，脚本只打印提示。**

```bash
# 1) 内容对了吗
sed -n '4p' /opt/napcat/launcher.sh
#    期望: exec xvfb-run -a env LD_PRELOAD=./libnapcat_launcher.so /opt/QQ/qq --no-sandbox -q 10002 "$@"

# 2) 备份在吗
ls -1 /opt/napcat/launcher.sh.bak-*

# 3) 重启（人来做）
systemctl restart napcat
sleep 45

# 4) 没弹二维码 / 没有扫码日志
journalctl -u napcat -n 100 --no-pager | grep -iE 'qrcode|扫码|login' || echo "no login prompt — good"

# 5) 业务侧通
#    用 deploy/fix-restart-napcat.sh 的 ws://127.0.0.1:3001 探活，或直接看 bridge 是否在线

# 6) 按 migration-runbook.md §6 的最终验收：连续两次 restart 都不再要求扫码
systemctl restart napcat && sleep 45 && journalctl -u napcat -n 50 --no-pager
```

对照 `docs/migration-runbook.md`：
- §5 暗伤表第 1 行「每次重启都要扫码登录」→ 本文交付脚本 + 文档后可置为「已修」；
- §2 时间线「T-1 天 旧机配好快速登录并验证一次重启免扫码」→ 用上面第 1–5 步；
- §6 观察清单末条「连续两次 restart 都不再要求扫码」→ 上面第 6 步。

---

## 附录：脚本用法

```bash
bash deploy/enable-quick-login.sh                     # 默认 --dry-run，只打印将改什么 + diff
bash deploy/enable-quick-login.sh --apply             # 真改（先备份）
bash deploy/enable-quick-login.sh --rollback          # 用最近一份备份还原
bash deploy/enable-quick-login.sh --account 123456789 # 换账号（默认 10002）
bash deploy/enable-quick-login.sh --file /path/launcher.sh   # 换目标文件
bash deploy/enable-quick-login.sh --service napcat    # 换服务名（只影响提示文案）
bash deploy/enable-quick-login.sh --help
```

幂等性：目标行已带 `-q <该账号>` 时，`--apply` 打印"幂等：不做任何改动"并以 0 退出，不产生多余备份。

来源标注：
- 官方文档 <https://napneko.github.io/guide/boot/Shell>（快速登录 `-q 123456789`）
- 本机发行包示例 `/opt/napcat/napcat/quickLoginExample.bat`、`/opt/napcat/napcat/launcher-win10-user.bat`
- 线上只读实测（`ls` / `cat` / `systemctl cat`），采集于本次任务
