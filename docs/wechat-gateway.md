# 微信通道（小号）

目标：她能在**你的小号微信**上跟人聊天，用的是同一套人设/记忆/工具，只是换了个"嘴"和"耳朵"。

## 三块职责（为什么要拆成三个进程）

| 块 | 跑在哪 | 权限 | 干什么 |
| --- | --- | --- | --- |
| `wx-read.py` | 本机（普通权限） | 读文件即可 | 直接读微信本地库（`xwechat_files/wxid_*/db_storage`），把新入站消息捞出来 |
| `wx-gateway.py` | 本机（普通权限） | 无 | 轮询 → 调她的大脑 → 把回复交给发送口 |
| `wx-helper.py` | 本机（**管理员**，常驻 127.0.0.1:3031） | 高完整性 | 恢复窗口 + UIA 发送 |

大脑在云上：`POST /node/ask`（bridge 新增，纯文本问答，不走 QQ 投递）。

## 为什么发送必须提权

`Weixin.exe` 跑在比我们高的完整性级别：

- 普通进程看不到它的进程与模块（`EnumProcesses` 只回 43 个进程，里面没有 Weixin；`psutil` 同样看不到）；
- `OpenProcess(PROCESS_VM_READ)` 直接 `WinError 5`；
- 于是 wechatauto 的 UIA"热激活"永远报 `PID xxxx 未找到 Weixin.dll`，控件树不物化，任何靠控件的发送都失败。

提权后同一条链路立刻通：`热激活 UIA：PID=32540 Weixin.dll+0xb3959d8: 0 -> 1` → `UIA 树已物化` → `已启用 UIA 驱动（混合路径：UIA 优先，OCR 兜底）`。

所以：**读库不提权，发送必须提权**。提权只做一次（一个常驻进程），不要每次发消息弹 UAC。

## 两个坑（都踩过）

1. **窗口最小化时找不到主窗口**：`GetWindowRect` 对最小化窗口返回 160x28 这类尺寸，按"大窗口"过滤会得到 `no main window`。必须先拿任意尺寸的句柄 `ShowWindow(hwnd, 9)` 再重新找。
2. **发送函数的数据库确认不可信**：`send_msg(..., verify=True)` 会报 `消息已操作发送，但数据库未确认（等了 8s）`，而消息其实已经发出去了（8 秒后 `filehelper` 里就有那行）。网关侧用 `verify=False`，自己读库复核。

## 判别「谁说的」（踩过的坑）

消息行里**没有** `is_sender` 字段。方向只能看两个：

- `sender_id == 1` → 自己发的；
- 否则是对方，`sender_username` 是对方的 wxid。

一开始按 `r.get('is_sender')` 过滤，等于永不过滤：她自己的回复被当成"新消息"再读进来，网关会跟自己聊上一个无限回环（日志里能看到「收到啦：收到啦：收到啦：…」一层层套下去）。

## 鉴权

- bridge：`Authorization: Bearer <NODE_TOKEN>`（`bridge/src/http.js` 只认这个头）。
- 本机 helper：`x-token: <helper-token.txt>`。
- 两者都只绑 127.0.0.1；bridge 通过 SSH 隧道暴露给本机（`-L 127.0.0.1:8790:127.0.0.1:8787`），因为阿里云安全组没开 8787。

## 文件

- `wechat-gateway/wx-read.py` 读新消息（`--sessions` / `--new` / `--baseline`）
- `wechat-gateway/wx-gateway.py` 主循环
- `wechat-gateway/wx-helper.py` 常驻发送服务
- `wechat-gateway/helper-token.txt`、`gateway.json` 本地凭据（不要提交、不要外发）

## 已验证

- 收：主号发「在吗」→ `--new` 抓到 `{"user":"wxid_a2yk8epulskj22","seq":1793201163000,"type":"文本","text":"在吗"}`
- 发：`POST /send` → `{"ok":true,"result":"{'status': '成功', 'message': '消息已发送：…'}"}`，库里可查到同一行

## 常驻与恢复（主人选了「维持现状」，所以这一切跑在他的笔记本上）

| 组件 | 谁拉起 | 断了怎么办 |
| --- | --- | --- |
| SSH 隧道 8790→云上 8787 | `wx-daemon.py` | 每 4 分钟探一次端口，down 就重拉 |
| 网关循环 `wx-gateway.py` | `wx-daemon.py`（看 `gateway.heartbeat` 是否新鲜） | 心跳超过 90 秒没更新就重启 |
| 发送 helper 3031 | 计划任务 `dsh-wx-helper`（ONLOGON / HIGHEST） | 守护只记一行 `helper=DOWN(run wx-helper-admin.cmd)`，不自动提权 |
| 开机自启 | `%APPDATA%\…\Startup\dsh-wx-daemon.cmd` | 登录即起，无需管理员 |

**一次性准备**：`install-helper-task.cmd`（右键 → 以管理员身份运行）注册 `dsh-wx-helper`；之后开机不再弹 UAC。没注册时双击 `wx-helper-admin.cmd` 也能用，但要过 UAC。

**看状态**（不用猜）：

```powershell
Get-Content C:\Users\lenovo\Documents\deepseek-harness\default-workspace\qq-dsh\wechat-gateway\supervisor.log -Tail 5
Get-Content …\wechat-gateway\gateway.log -Tail 20
```

supervisor 每次运行都写一行（`tunnel=up gateway=up helper=up`），**日志是空的就说明守护没在跑**。

**单实例**：网关与守护各自持有 `gateway.lock` / `daemon.lock`（`msvcrt.locking`），重复启动会直接退出——两个网关会把一条消息回两遍。

**边界（重要）**：笔记本关机、微信退出或断网，微信这条路就断；QQ 在云上不受影响。她的记忆里已写进这条事实（`MEMORY.md` 2026-10-28 那行），别让她再说「你电脑关了我照样在微信上」。


## 图片与语音入站（2026-10-29 加）

她要能看懂主人发来的图和语音，光靠「文字」那条链路不够，所以补了两段：

| 环节 | 谁做 | 说明 |
| --- | --- | --- |
| 认出媒体消息 | `wx-read.py` | 行里带 `type`（图片/语音）、`localId`、`shard`；网关只把 `图片`/`语音` 当媒体，其余非文本照旧跳过 |
| 取字节 | `wx-media.py`（子进程） | `MediaDownloader.download_image/download_voice`；图片落原图（jpg/png/gif），语音落 `.silk` |
| 语音转音频 | `wx-media.py` + `pilk` | 微信语音是 SILK，DashScope 不认；`pilk.decode(silk, pcm, 24000)` 出裸 PCM16，再自己写 WAV 头（1 秒 ≈ 48KB） |
| 送进她的大脑 | `wx-gateway.py` | 图片进 `images:[{mime,dataBase64}]`，语音进 `audios:[{mime,dataBase64}]`，随 `/node/ask` 一起发 |
| 解图密钥 | helper `POST /image-key` | `MediaDownloader.detect_image_key(refresh=True)` 要扫 Weixin.exe 内存 → 必须提权，所以放在 helper 里；网关遇到 `image_not_decodable` 会先要一次密钥再重取 |

降级（都不抛错，只影响这一条消息）：图取不到 → 文本里加「[图片在我这边没打开，我看不到这张图]」；语音取不到 → 加「[有一条语音我这边没转出来，没听见内容]」；纯语音没有文字时若旧桥回 400，会补一句 `[语音]` 再问一次。

**已知门槛**：`image_keys.json` 只有在微信里**点开过至少一张图**之后才导得出来。小号还没开过图时 `/image-key` 返回 `{"key":false}`，此时图片一律按上面那条降级走。开图后调一次 `POST /image-key` 即可。

**两个坑**（都踩过）：计划任务里的 `TMP` 不可用，`tempfile.gettempdir()` 直接抛 `No usable temporary directory`；而 `WeChatDB()` 的 workdir 就等于 `<gettempdir>\wechatauto_db\<账号>`，所以**不能**随便换 temp 目录——换成别的目录等于把 `keys.json` 挪走。正解是把 `tempfile.tempdir` 指向已经存在 `wechatauto_db` 的那一层（`wechat-gateway` 上两级）。


- 图：`/node/ask` + 96×96 红 PNG（2026-10-29）→ `ok:true, ms:4581`，她回「主要是红色的呀～」
- 语音：`/node/ask` + 一条 mp3、`text` 为空 → `ok:true, ms:3314`，先转写再回「茶茶早呀～…」


## 暂停状态（2026-10-29 15:06，用户指示「接入微信计划暂停」）

停下来的原因不是坏掉，而是用户决定先不做这条线；代码、密钥、文档全部保留，随时可续。

### 已停的进程（全部手动杀掉，不留自启）
- `wx-gateway.py`（轮询 + 转发 + 发件箱）、`wx-daemon.py`（4 分钟探活）、`wx-helper.py`（提权发送器）
- `ssh -L 8790` 隧道（指向云上 bridge 8787）
- 开机自启项 `%APPDATA%\...\Startup\dsh-wx-daemon.cmd` 与计划任务 `dsh-wx-helper` **仍在**，恢复时不用重建；不想恢复就把这两处删掉。

### 遗留
- 一个提权 helper 仍监听 `127.0.0.1:3031`（pid 见 `Get-NetTCPConnection -LocalPort 3031`）。它是用户级权限进程，沙箱内杀不掉；注销/重启即消失，或手动 `taskkill /F /PID <pid>`。

### 恢复要做的事（按顺序）
1. `Start-Process -Verb RunAs .venv\Scripts\pythonw.exe -ArgumentList wx-helper.py`（提权，别用计划任务，见下）
2. 起隧道 `ssh -N -L 127.0.0.1:8790:127.0.0.1:8787 root@203.0.113.10`
3. `.venv\Scripts\pythonw.exe wx-gateway.py`（单实例锁 `gateway.lock`）
4. 想让微信窗口保持可见——这是必要条件，见「已知硬门槛」。

### 这次真正验通与没验通的
- 验通：DB 解密读消息（`keys.json` 19/20）、按 `sender_id` 判别收发、`/node/ask` 端到端（13:09 他发「在吗」→ 她答 → `send -> 擪釰？ ok=True`）、提权 helper 发消息（15:00「自测3」、15:01「自测4」都落到会话里）。
- 没验通/没做：图片密钥（`image_keys.json` 需在微信里点开一张大图）、`message/media_0.db` 密钥（语音，需播一次）、群聊只回 @、发语音。
- 新加未上线的韧性：`wx-gateway.py` 的 `OUTBOX_MAX_TRIES=8` / `OUTBOX_TTL=900` 发件箱，发送失败会排队重试，窗口恢复后自动补发（本轮重启后尚未遇到失败场景实测）。

### 已知硬门槛（决定性，写在最显眼处）
- **微信主窗口必须可见且未最小化**：`wx-helper.py` 的窗口操作（`ShowWindow`/`SetWindowPos`/`SetForegroundWindow`）在本机一律返回失败，窗口最小化时发送会报 `微信窗口不可见（可能锁屏/会话断开）`。
- 沙箱起的微信进程拒绝外部 `OpenProcess`（err=5），UIA 热激活无法做，只剩 OCR；OCR 也要求窗口在屏幕上。因此「用户自己开的微信 + 提权 helper + 窗口可见」是唯一稳定组合。
- `C:\Users\lenovo\xwechat_files` 对沙箱进程不可写，但读库不受影响。
