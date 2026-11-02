# DSH × QQ 部署 Runbook

把 DSH agent 接到 QQ：**QQ ←→ NapCat（云端）←→ bridge（云端）←→ SSH 隧道 ←→ node-plugin（本机 Windows）**。

- 云端：阿里云 **Ubuntu 22.04.5 LTS (Jammy) x86_64**，已 root、有公网 IP，**已体检**（实测值见 S1，不用再猜发行版）。
- 本机：Windows，PowerShell 5.1，OpenSSH_for_Windows_9.5p2，自带 `tar.exe` / `curl.exe` / `scp.exe`（均已在本机核实）。
- 契约来源：`qq-dsh/PROTOCOL.md`（协议）与 `qq-dsh/PLAN.md`（部署契约）。本文与之一致，冲突以那两份为准并回报。

## ⚠️ 先读：硬性禁令（2026-10-24 事故记录）

**事故**：2026-10-24 18:43:12，开发本项目的子代理为清理测试进程，执行了

```
Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force
```

DSH 宿主本身也是 node 进程，被一并杀死：web 面板从 18:43 停到 19:02（用户手动重启），
期间所有会话无法回答、未送达的消息全部丢失。文件与数据未损坏，重启即恢复。

**硬性禁令**：在任何运行 DSH 的机器上（本机、云主机、CI），禁止以下「按映像名批量杀进程」的写法：

- `Get-Process node | Stop-Process -Force`
- `taskkill /F /IM node.exe`
- `killall node` / `pkill -f node`

**正确做法**：先按端口或已知 PID 定位，只杀目标进程：

```powershell
# 按端口找监听进程（例：bridge 8787、NapCat 3001、web 3080）
$owners = (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue).OwningProcess
foreach ($p in $owners | Select-Object -Unique) { Stop-Process -Id $p -Force }

# 或只杀自己启动并记录过的子进程 PID
Stop-Process -Id <PID> -Force
```

DSH 本体、`qq` profile、测试里的 node 子进程全部是 `node.exe`——按名字杀必然连宿主一起带走。
动手前先确认目标 PID 不是监听 3080 的 web 进程，也不是自己所在的进程树。

---

## 0. 怎么用这份文档

**0.1 每一步都是三段式**

```
【命令】 可直接复制（尖括号 <...> 是占位符，要替换）
【预期】 看到什么才算过
【失败】 怎么办（先看 S15 故障表）
```

**0.2 版本免责**

NapCat 迭代很快，**安装方式与界面文案可能随版本变化，一切以官方文档为准**。本文不复制二手教程的命令；
NapCat 的安装命令请到官方页面（见 S7）复制，本文只规定「装完必须达到的配置结果」。

原因写在这里，免得你觉得我偷懒：**服务器侧的连通性已经实测**（见 S1.2：`nodejs.org` 200/4.464 s、
`registry.npmmirror.com` 200/0.177 s、`github.com` 200/0.728 s、`registry-1.docker.io` 000），
但**写本文的本机仍然没有外网**，抓不到 NapCat 的页面正文。**编造命令比不给命令更危险**，所以 S7 给的是
「官方入口 + 判据」，而不是背诵的命令串。S3 是唯一的例外：那段脚本每一步都能用 `SHASUMS256.txt`
自校验，所以给了逐字可跑的命令。

**0.3 必须你自己动手、我无法代劳的事**

| 事项 | 为什么不能代劳 |
|---|---|
| 阿里云安全组放行 22 | 需要你的云控制台权限 |
| 在服务器上跑本文的每条命令 | 我没有那台机器的访问权 |
| NapCat WebUI 用手机 QQ 扫码登录 | 需要你的 QQ 号与手机 |
| 填 `OWNER_QQ`、两个 token | 属于你的私密信息 |
| 手机号/实名/设备锁相关的账号设置 | 账号安全设置只能本人改 |
| 决定要不要用专用小号、承担封号风险 | 风险决策归你（见 S14） |

**0.4 占位符**

| 占位符 | 含义 | 例 |
|---|---|---|
| `<SERVER_IP>` | 阿里云公网 IP | `47.100.x.x` |
| `<SSH_USER>` | SSH 用户 | `root` |
| `<OWNER_QQ>` | 你自己的 QQ 号（唯一 owner） | `1000000000` |
| `<NODE_TOKEN>` | 本机→bridge 的 Bearer token | `openssl rand -hex 32` 生成 |
| `<NAPCAT_TOKEN>` | bridge→NapCat 的 token | `openssl rand -hex 32` 生成 |

---

## 1. 安全模型：为什么安全组只开 22

```
QQ 服务器
   │  (NapCat 主动出站长连接)
   ▼
[云端]  NapCat  ──WS(127.0.0.1:3001)──►  bridge  ──HTTP(127.0.0.1:8787)
                                                    ▲
                                                    │  SSH 端口转发
                                                    │  （本机主动出站发起）
[本机]  ssh -N -L 127.0.0.1:8787:127.0.0.1:8787 ────┘
```

三条理由：

1. **bridge 只绑回环**，`BRIDGE_HOST=127.0.0.1`。绑在 127.0.0.1 的端口不会被网卡转发出去，
   公网、VPC 内其它机器、同机其它网卡都连不上；即使安全组开了 8787 也连不上。
   （反过来：契约要求 `BRIDGE_HOST=0.0.0.0` 时 bridge 必须拒绝启动，这是防你手滑。）
2. **隧道由本机主动出站建立**。NAT 默认放行出站，所以云端**不需要任何入站规则**，除了 SSH。
3. **少开一个端口就少一个攻击面**。如果 8787 对公网开放，`NODE_TOKEN` 会在**明文 HTTP** 里
   随每个请求传输（协议是 `http://`，没有 TLS）——抓包即可拿到，等于把 bridge 交给全网。
   走 SSH 隧道时，这层明文被 SSH 加密包住。

**所以：安全组入方向只需 `22/tcp`。** 建议把 22 的源地址也限制成你的常用 IP（家里/公司），
不要 `0.0.0.0/0`；如果必须全网，至少装 `fail2ban`。

> 反面清单（有人这么干过，别学）：把 `BRIDGE_HOST` 改成 `0.0.0.0` 图省事 —— bridge 会直接拒绝启动；
> 用 `nginx` 反代 8787 到公网 —— 等于明文暴露 token；在安全组开 3001 想让"外面也能连 NapCat" —— 毫无必要，
> NapCat 和 bridge 在同一台机器上。

**S0 验收**：云控制台 → 安全组入方向规则里，除 22 外没有与本项目相关的端口。
（出方向保持默认全放行即可，NapCat 要出站连 QQ 服务器。）

---

## 2. S1 体检记录（实测，已确认）

本节原先是一张「你去查、再把结果记下来」的清单。**这些值已经在你那台机器上测过了**，所以下面直接给
实测值；`【命令】`保留，用途从"必做"降级为"复核 / 换机器时重跑"。

【命令】（复核用，不是必做）

```bash
cat /etc/os-release | head -4
uname -m
ldd --version | head -1
nproc; free -m | head -2; df -h / | tail -1
command -v docker  && docker --version  || echo "NO_DOCKER"
command -v node    && node -v          || echo "NO_NODE"
systemctl --version | head -1
timedatectl | head -3
```

### 2.1 实测值（已确认）

| 检查项 | 实测值 | 结论 |
|---|---|---|
| 发行版 | **Ubuntu 22.04.5 LTS (Jammy) x86_64** | 本文全部前提成立，不需要"发行版未知"式的分支 |
| 镜像来源 | 阿里云 `ubuntu_22_04_x64_20G_alise_20260916.vhd` | 名字里的 `20G` 是**控制台模板名**，不是盘容量（见 2.3） |
| 架构 | `x86_64` | 下文 `NARCH` 固定为 `linux-x64` |
| glibc | **2.35**（Ubuntu GLIBC 2.35-0ubuntu3.15） | ≥ 2.28，官方 Node 24 linux-x64 产物可直接跑，**不需要换系统** |
| systemd | **249**（249.11-0ubuntu3.23） | 存在且够用，本文 systemd 部分全部适用 |
| 时钟 / 时区 | `timedatectl` 已同步：Local **CST** / UTC / RTC 三者一致 | 不需要 `timedatectl set-ntp true`；消息时间戳不会乱 |
| CPU | **4 核** vCPU | 充裕（bridge 是单进程 Node） |
| 内存 | total **7522 MB** / available **6782 MB** | 充裕：NapCat + bridge 合计 < 1 GiB |
| 磁盘 | `/dev/vda3`：**40 G total，已用 5.6 G，可用 32 G** | 充裕，**不需要清盘**（原因见 2.3） |
| Docker | **`NO_DOCKER`**（未安装） | 且 Docker Hub 不可达（见 2.2）→ S7 走裸机安装器 |
| Node | **`NO_NODE`**（未安装） | S3 必做 |
| apt 源 | `mirrors.cloud.aliyuncs.com/ubuntu jammy {main,restricted,universe}`（阿里云内网镜像） | 装 `xz-utils` / `python3` 等系统包很快 |

**这两项已确认**：`NO_DOCKER` 与 `NO_NODE`。S3（装 Node）与 S7（装 NapCat）按此执行，不用再探测。

### 2.2 网络探测记录

测法（逐条跑，看状态码与耗时）：

```bash
for u in https://nodejs.org/dist/index.json \
         https://registry.npmmirror.com/-/binary/node/ \
         https://mirrors.aliyun.com \
         https://github.com \
         https://registry-1.docker.io/v2/; do
  printf '%s -> ' "$u"
  curl -o /dev/null -sS -m 20 -w '%{http_code} %{time_total}s\n' "$u"
done
```

实测结果（原始值，未做美化）：

| URL | HTTP 码 | 耗时 | 判读 |
|---|---|---|---|
| `https://nodejs.org/dist/index.json` | `200` | **4.464 s** | 可达但慢（比 npmmirror 慢约 25 倍）→ **不作 Node 主源** |
| `https://registry.npmmirror.com/-/binary/node/` | `200` | **0.177 s** | 快 → **Node 二进制主源**，S3 用这个 |
| `https://mirrors.aliyun.com` | `301` | **0.084 s** | 正常重定向（站点根路径必须跳转）→ 阿里云镜像站可用，与 apt 源一致 |
| `https://github.com` | `200` | **0.728 s** | 可达 → **NapCat 裸机安装器从 GitHub 拉**（S7） |
| `https://registry-1.docker.io/v2/` | `000` | **4.202 s** | **连不上** → Docker Hub 不可达，Docker 路线在本机是死路 |

**判读结论（三条，直接决定后面几节的路线）**：

1. **Node 走 npmmirror**：`200` / `0.177 s`，且带官方 `SHASUMS256.txt` 可校验 → S3 用它。
   `nodejs.org` 只是"通"，不是"好用"（4.464 s 是首包，下 tarball 只会更慢）。
2. **NapCat 走 GitHub 裸机安装器**：`github.com` `200` / `0.728 s`，`napcat-linux-installer` 拉得动 → S7 主路径。
3. **Docker Hub 不可达**（`000`）。所以 Docker **不是**本机可用的路线，S7 里只留一段说明，
   供将来换成能访问 Docker Hub 的网络环境时再评估。

> `000` 的含义：curl 没拿到任何 HTTP 状态码（连接超时 / DNS 解析失败 / 被中间设备丢弃）。
> 它不是"服务器返回了 0"，所以不能按"接口报错"去排查，只能按"网络层不通"处理。

### 2.3 关于镜像名里的 `20G`（重要，别再拿它当容量）

控制台上的镜像名 `ubuntu_22_04_x64_20G_alise_20260916.vhd` 里那个 `20G` 是**阿里云镜像模板的编号**，
**不是这台机器系统盘的容量**。`df -h` 的实测值是 `/dev/vda3` **40 G total / 已用 5.6 G / 可用 32 G**。

**本文任何容量判断一律以 `df -h` 为准，不以镜像名为准。** 按实测容量算：Node 解包约 200 MB、
NapCat + LinuxQQ 约 1 G、`queue.db` + `blobs/` 按 T1 的保留策略增长，全部装完离 32 G 的可用量还差一个量级。
所以**不存在"盘紧张"这回事**，不需要为了省盘去定期清日志、也不需要裁剪保留策略或图片缓存。

---

## 3. S2 创建运行用户与目录

按 `PLAN.md` 部署契约：用户 `dshqq`、`/opt/dsh-qq-bridge`、`/var/lib/dsh-qq-bridge`、`/etc/dsh-qq-bridge`。

【命令】

```bash
getent group dshqq >/dev/null || groupadd --system dshqq
id -u dshqq >/dev/null 2>&1 || useradd --system \
  --gid dshqq --home-dir /var/lib/dsh-qq-bridge --no-create-home \
  --shell /usr/sbin/nologin --comment "DSH QQ bridge" dshqq

install -d -o root  -g root  -m 0755 /opt/dsh-qq-bridge
install -d -o root  -g root  -m 0755 /etc/dsh-qq-bridge
install -d -o dshqq -g dshqq -m 0700 /var/lib/dsh-qq-bridge
install -d -o dshqq -g dshqq -m 0700 /var/lib/dsh-qq-bridge/blobs

id dshqq
ls -ld /opt/dsh-qq-bridge /etc/dsh-qq-bridge /var/lib/dsh-qq-bridge /var/lib/dsh-qq-bridge/blobs
```

【预期】

```
uid=99x(dshqq) gid=99x(dshqq) groups=99x(dshqq)
drwxr-xr-x root  root  /opt/dsh-qq-bridge
drwxr-xr-x root  root  /etc/dsh-qq-bridge
drw------- dshqq dshqq /var/lib/dsh-qq-bridge
drw------- dshqq dshqq .../blobs      ← 0700：数据目录只给 dshqq
```

【失败】`useradd: group 'dshqq' does not exist` → 先跑第一行 `groupadd`。
`--shell` 报路径不存在 → 改成 `--shell /bin/false`（系统用户不登录，无所谓）。

> **为什么数据目录必须 dshqq 拥有**：`/var/lib/dsh-qq-bridge` 在 systemd 里由
> `StateDirectory=dsh-qq-bridge` + `ProtectSystem=strict` 放行写权限。如果目录属主是 root，
> bridge 一写 `queue.db` 就 `EACCES`，而这个错误藏在 journal 里很久才发现。上面 `ls -ld` 就是自查。

---

## 4. S3 安装 Node 24（走 npmmirror）

bridge 用 `node:sqlite` + 内置 `WebSocket`，**必须 Node 24**。

**为什么走 npmmirror 而不是 nodejs.org**（实测见 S1.2）：`nodejs.org` 通，但拿到 JSON 要 **4.464 s**；
`registry.npmmirror.com` 只要 **0.177 s**，快约 25 倍。npmmirror 是 nodejs.org 的二进制镜像，
**同样提供官方 `SHASUMS256.txt`**，所以"换源"并没有牺牲校验链。本机 `NO_NODE`（未安装，见 S1），本节必做。

### 4.1 先看现成的

【命令】

```bash
command -v node && node -v
```

【预期】

- 打印 `v24.x.x` → 跳到 4.3（记下 `command -v node` 的路径，S6 要用）。
- 打印 `v18/v20/v22` 或 `NO_NODE` → 继续 4.2。

### 4.2 安装脚本（npmmirror 源 + SHA256 校验）

【命令】逐字复制，**不要改动命令本身**（改一处就可能绕过下面的校验）：

```bash
# 1. 取最新 v24 版本号
VER=$(curl -sSL -m 30 https://registry.npmmirror.com/-/binary/node/index.json \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(max((v['version'] for v in d if v['version'].startswith('v24.')),key=lambda s:tuple(int(x) for x in s[1:].split('.'))))")
echo "target=$VER"

# 2. 下载并校验
cd /tmp
curl -fL --retry 3 -m 600 -O "https://registry.npmmirror.com/-/binary/node/${VER}/node-${VER}-linux-x64.tar.xz"
curl -fL --retry 3 -m 60  -O "https://registry.npmmirror.com/-/binary/node/${VER}/SHASUMS256.txt"
grep " node-${VER}-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c -

# 3. 安装到 /usr/local/lib/nodejs
mkdir -p /usr/local/lib/nodejs
tar -xJf "node-${VER}-linux-x64.tar.xz" -C /usr/local/lib/nodejs
for f in /usr/local/lib/nodejs/node-${VER}-linux-x64/bin/*; do
  ln -sf "$f" "/usr/local/bin/$(basename "$f")"
done

# 4. 验证
node -v && npm -v && command -v node
```

【说明】

- **第 1 步**只取版本号、不落盘。`max(...)` 让脚本自己挑当前最新的 `v24.*`，所以不需要写死版本号。
- **第 2 步的校验行必须过**：`grep " node-${VER}-linux-x64.tar.xz$" SHASUMS256.txt | sha256sum -c -`
  输出 `node-v24.x.y-linux-x64.tar.xz: OK` 才算过。若打印 `FAILED`，或 `no properly formatted
  checksum lines found` / `grep: SHASUMS256.txt: No such file`，**停下，不要跳过校验继续装** ——
  跳过校验等于把一个没验过的二进制 `ln` 到 `/usr/local/bin` 上，而且它随后会以 root 身份跑 bridge。
- 若 `tar -xJf` 报 xz 不支持（`xz: Cannot exec` / `tar: unrecognized option`），先
  `apt-get install -y xz-utils`（apt 走阿里云内网源 `mirrors.cloud.aliyuncs.com`，很快）。
- **第 3 步用 `for f in bin/*` 而不是硬写 `node npm npx corepack`**：Node 24 起 `corepack` 可能不再随包提供，
  硬写会在 `ln` 处 `No such file or directory` 直接失败（`tar` 已经解开了，失败却发生在链接阶段，
  现场看起来像"装了一半"）。遍历目录则是"有哪些就链哪些"。
- 产物目录是 `/usr/local/lib/nodejs/node-<VER>-linux-x64`。**升版就改 `VER` 重跑本节**，
  旧目录留着不动：`ln -sf` 会把 `/usr/local/bin/*` 改指到新版本，回滚也只是再指回去。

【预期】

```
target=v24.x.y
node-v24.x.y-linux-x64.tar.xz: OK
v24.x.y
10.x.y
/usr/local/bin/node
```

（第 2、3 行之间的 `curl` 进度条输出略。`npm -v` 的主版本号随 Node 24 走，`10.x` 只是示意。）

【失败】

- 第 1 步 `python3: command not found` → `apt-get install -y python3`（jammy 一般自带）。
- 第 2 步 `curl: (22) ... 404` / `(6) Could not resolve host` → npmmirror 上该版本文件缺失或网络抖动，
  重跑一次；仍失败就按 `https://nodejs.org/dist/index.json` 的版本号手工传 `VER`（本机 nodejs.org 慢但通，
  4.464 s 是首包，tarball 会明显更慢 —— 只在镜像缺文件时才用这条退路）。
- 第 3 步 `tar` 报 `xz` → 见上面的 `xz-utils`。
- 第 4 步 `node: error while loading shared libraries` / `version 'GLIBC_2.28' not found` → glibc 太老。
  **本机 glibc 是 2.35（见 S1），不会踩这个**；换机器时才需检查。

### 4.3 验证 Node 具备 bridge 需要的两个能力

【命令】

```bash
node -v
node -e "const { DatabaseSync } = require('node:sqlite'); console.log('node:sqlite OK')"
node -e "console.log('WebSocket:', typeof WebSocket)"
```

【预期】

```
v24.x.y
node:sqlite OK
WebSocket: function
```

`ExperimentalWarning: SQLite is an experimental feature` 这类警告**正常**，不影响使用。

【失败】`node:sqlite` 报 `Cannot find module` → Node 版本不够（< 22.5）或装成了别的版本，
回到 4.2 重装（旧的 `/usr/local/bin/*` 软链会被新的 `ln -sf` 覆盖）。`WebSocket: undefined` → 同上。

---

## 5. S4 上传 bridge 代码

`bridge/` 由 T1 交付。若目录还不存在或没写完，**先跳过本节**，做完 S2/S3 与 S7 再来。

### 5.1 在 Windows 本机打包并上传

【命令】（Windows PowerShell，不是服务器）

```powershell
cd C:\Users\lenovo\Documents\deepseek-harness\default-workspace\qq-dsh
tar -czf $env:TEMP\dsh-qq-bridge.tgz bridge
scp $env:TEMP\dsh-qq-bridge.tgz <SSH_USER>@<SERVER_IP>:/tmp/
```

【预期】`ls` 能看到 `C:\Users\...\Temp\dsh-qq-bridge.tgz`，`scp` 最后打印 `100% ... dsh-qq-bridge.tgz`。

【失败】`scp: command not found` → 装「OpenSSH 客户端」可选功能。
`Permission denied (publickey,password)` → 见 S10 的密钥配置（先配好密钥再来）。

### 5.2 在服务器解包

【命令】

```bash
ls -l /tmp/dsh-qq-bridge.tgz
tar -xzf /tmp/dsh-qq-bridge.tgz -C /opt/dsh-qq-bridge --strip-components=1
ls -la /opt/dsh-qq-bridge
find /opt/dsh-qq-bridge -maxdepth 2 -type f | sort | head -30
chown -R root:root /opt/dsh-qq-bridge
chmod -R go-w /opt/dsh-qq-bridge
```

【预期】能看到入口 `bin/bridge.js`（契约要求），以及 `package.json`、`src/`、`test/`。
属主全是 `root root`。

【失败】`bin/bridge.js` 不存在 → T1 交付形态与契约不符，**停在这里并回报**，不要自己改 T1 的文件。

【命令】预检语法（可选）

```bash
node --check /opt/dsh-qq-bridge/bin/bridge.js && echo "语法 OK"
```

【预期】`语法 OK`。若报 `Cannot use import statement outside a module` 之类的 ESM 解析错，
说明 `--check` 没按 ESM 解析，**可以忽略**，以 S6 的实际启动结果为准。

---

## 6. S5 写 env 文件（0600）

### 6.1 生成两个 token（在服务器上）

【命令】

```bash
echo "NAPCAT_ACCESS_TOKEN=$(openssl rand -hex 32)"
echo "NODE_TOKEN=$(openssl rand -hex 32)"
```

【预期】两行 64 位十六进制。`NODE_TOKEN` 那一行**记在本地密码管理器里**，S12 要用。

### 6.2 上传模板并填写

【命令】（Windows 本机）

```powershell
cd C:\Users\lenovo\Documents\deepseek-harness\default-workspace\qq-dsh\deploy
scp env.example dsh-qq-bridge.service <SSH_USER>@<SERVER_IP>:/tmp/
```

【命令】（服务器）

```bash
install -m 0600 -o root -g root /tmp/env.example /etc/dsh-qq-bridge/env
nano /etc/dsh-qq-bridge/env      # 把 3 个 REPLACE_WITH_* 和 OWNER_QQ 换成真值
```

要改的四行：

```
NAPCAT_ACCESS_TOKEN=<上面的 NAPCAT_ACCESS_TOKEN>
NODE_TOKEN=<上面的 NODE_TOKEN>
OWNER_QQ=<你自己的 QQ 号>
```

其余 6 个键**保持原样**（`NAPCAT_WS_URL` / `BRIDGE_HOST` / `BRIDGE_PORT` / `BACKLOG_TTL_MS` /
`DB_PATH` / `BLOB_DIR`），必需的就是这 **9 个**，与部署契约逐字一致。之后按需追加语音、主动开口、
世界线那些键（见附录 A 的「可选键」表），所以**别把总行数当校验条件**——线上现在 47 行。

### 6.3 自查

【命令】

```bash
ls -l /etc/dsh-qq-bridge/env
grep -cE '^[A-Z_][A-Z0-9_]*=' /etc/dsh-qq-bridge/env
grep -n 'REPLACE_WITH' /etc/dsh-qq-bridge/env || echo "占位符已全部替换"
grep -nE '^(BRIDGE_HOST|BRIDGE_PORT|DB_PATH|BLOB_DIR)=' /etc/dsh-qq-bridge/env
```

【预期】

```
-rw------- 1 root root ... /etc/dsh-qq-bridge/env     ← 0600
9 或更多                                              ← 必需的那 9 个一个不少（键名带数字的也要数到）
占位符已全部替换
BRIDGE_HOST=127.0.0.1
BRIDGE_PORT=8787
DB_PATH=/var/lib/dsh-qq-bridge/queue.db
BLOB_DIR=/var/lib/dsh-qq-bridge/blobs
```

【失败】

- 比 9 少 → 你漏写或写错了键名，对照 `env.example` 的注释头；比 9 多是正常的（装语音、主动开口、世界线时会往上加）。
- `BRIDGE_HOST` 不是 `127.0.0.1` → 改回来（否则 bridge 拒启动，或更糟：暴露公网）。
- env 文件里**不要**写 `export`、不要给值加引号、不要行尾 `# 注释` —— systemd 的
  `EnvironmentFile=` 不解这些，会导致值里带上引号字符，报鉴权失败却查不出来。

---

## 7. S6 安装 systemd 单元并启动

【命令】

```bash
install -m 0644 /tmp/dsh-qq-bridge.service /etc/systemd/system/dsh-qq-bridge.service

# 把 ExecStart 的 node 路径改成本机真实路径（tarball 装法是 /usr/local/bin/node）
NODE_BIN=$(command -v node)
echo "node = $NODE_BIN"
sed -i "s|^ExecStart=.*|ExecStart=${NODE_BIN} /opt/dsh-qq-bridge/bin/bridge.js|" \
  /etc/systemd/system/dsh-qq-bridge.service
grep -n '^ExecStart=' /etc/systemd/system/dsh-qq-bridge.service

systemd-analyze verify /etc/systemd/system/dsh-qq-bridge.service || true
systemctl daemon-reload
systemctl enable --now dsh-qq-bridge
systemctl status dsh-qq-bridge --no-pager
```

【预期】

```
ExecStart=/usr/local/bin/node /opt/dsh-qq-bridge/bin/bridge.js
● dsh-qq-bridge.service - DSH QQ bridge ...
     Loaded: loaded (/etc/systemd/system/dsh-qq-bridge.service; enabled; ...)
     Active: active (running) since ...
```

`systemd-analyze verify` **正常时不输出任何东西**。若打印 `Unit ... has a bad unit file setting`，
把原文记下来回报（我这边是 Windows，跑不了 systemd 校验，只能做静态核对）。

【命令】看日志与监听

```bash
journalctl -u dsh-qq-bridge -n 40 --no-pager
sudo ss -ltnp | grep 8787
curl -sS http://127.0.0.1:8787/health; echo
```

【预期】

```
LISTEN 0 511 127.0.0.1:8787 ...        ← 必须是 127.0.0.1，不能是 0.0.0.0 / * / [::]
{"ok":true,"queued":0,"uptimeMs":1234}
```

此刻日志里出现「连不上 NapCat」的重试是**正常的**（NapCat 还没装，S7/S8 之后消失）。
bridge 的要求是「连不上就退避重连、进程不退出」，所以 `active (running)` 应当保持。

【失败】

| 现象 | 原因 | 处置 |
|---|---|---|
| `status=203/EXEC` | ExecStart 的 node 路径不对 | 重跑上面的 `sed`，把 `NODE_BIN` 改成 `command -v node` 的实际输出 |
| `status=200/CHDIR` | `/opt/dsh-qq-bridge` 不存在 | 回 S4 |
| `status=1` + 日志 `EACCES ... queue.db` | 数据目录属主不是 dshqq | 回 S2 的 `install -d -o dshqq` |
| `status=1` + 日志提到 `BRIDGE_HOST` / `0.0.0.0` | env 里 host 写错了 | 回 S5，改成 `127.0.0.1` |
| `Active: failed` + 端口已被占用 | 8787 上有别的服务 | `sudo ss -ltnp | grep 8787` 找出占用者并停掉 |
| `ss` 显示 `0.0.0.0:8787` | env 的 `BRIDGE_HOST` 不是回环 | **立即**改回并在安全组确认没开 8787 |

> 本机是 Windows、跑不了 `systemd-analyze verify`。这个单元文件我做过的核对：
> 键名拼写、`[Unit]/[Service]/[Install]` 三节齐全、`EnvironmentFile=` 路径与契约一致、
> `ExecStart=` 指向 `bin/bridge.js`、**没有** 使用 `MemoryDenyWriteExecute=yes`（会让 V8 直接起不来，
> 这是 Node 服务最常见的 unit 踩坑）。你在服务器上跑一次 `systemd-analyze verify` 作为最终确认。

---

## 8. S7 安装 NapCat（裸机安装器是唯一主路径）

> **路线已定，不再是二选一**：**裸机安装器**（`napcat-linux-installer`）。
> Docker 路线在本机**不可用**，原因是实测的（`registry-1.docker.io` → `000`，见 S1.2 / 8.4），不是偏好。

> **前置声明**：NapCat 的 Linux 部署方式随版本变化较大。**安装命令请到官方页面复制**，本文只给入口、
> 路线和"装完必须达到什么"。

### 8.1 官方入口（都已核实存在）

| 用途 | 链接 |
|---|---|
| 主仓库 / Releases（看最新版本） | https://github.com/NapNeko/NapCatQQ |
| 官方文档 · Shell 引导（Linux 启动方式） | https://napneko.github.io/guide/boot/Shell.html |
| 同一文档的备用镜像域名 | https://doc.napneko.icu/guide/boot/Shell.html |
| 官方文档 · 框架/版本说明 | https://napneko.github.io/guide/boot/Framework |
| **官方 Linux 安装器仓库（本文主路径）** | https://github.com/NapNeko/napcat-linux-installer |
| 官方 Docker 镜像仓库（本机不可用，仅留档备查） | https://github.com/NapNeko/NapCat-Docker |
| 文档的另一渲染镜像（仅当上面都打不开时用） | https://mintlify.wiki/NapNeko/NapCatQQ/installation |

两件事请你先明白：

1. 上面每个链接的 **README / 页面正文就是安装说明**，照着页面里的代码块做，不要搜索"某某系统装 NapCat 教程"。
   二手教程最常见的坑是：端口绑成 `0.0.0.0`、消息格式选了 `string`、用了旧版 tag。
2. NapCat **必须有 QQ 客户端在跑**（它是注入/托管 QQ 的中间层）。裸机安装器会一并装齐官方 LinuxQQ 与
   NapCat，所以这一条由安装器负责，你不需要另外单独装 QQ。

### 8.2 走裸机安装器（主路径）

**为什么只有这一条**：`https://github.com` 实测 `200` / **0.728 s**（S1.2），安装器从 GitHub 拉得动；
而 `https://registry-1.docker.io/v2/` 实测 **`000`** / 4.202 s（连不上），Docker 这条路在这台机器上走不通。
机器本身也已确认 `NO_DOCKER`（未安装 Docker）。

【步骤】打开 https://github.com/NapNeko/napcat-linux-installer 的 README，按页面执行。
它负责装齐官方 LinuxQQ 与 NapCat，并生成启动入口。

【判据】装完立刻跑 **8.3 的统一验收**，另外确认启动入口：

```bash
ls -l /etc/systemd/system | grep -i napcat || echo "无 napcat systemd 单元"
```

有单元 → `systemctl enable --now <单元名>` 让它常驻；没有单元 → 按官方页面给的启动方式做，
并用 `nohup`/`tmux` 之外的正规手段（优先找官方是否提供 systemd 单元模板）。

【失败】安装脚本报依赖缺失 / 发行版不支持 → 回 8.1 第 2、3 行的官方 Shell 引导页面逐步排障。
**不要改去装 Docker**：那一步在这台机器上会因为连不上 Docker Hub 卡死，只是在浪费排查时间（见 8.4）。

### 8.3 装完的统一验收

【命令】

```bash
# 1) 进程在跑（本机是裸机安装，没有容器层，所以只看 ps）
ps -ef | grep -i [n]apcat | head -5

# 2) 监听端口长什么样
sudo ss -ltnp | grep -E '3001|6099|napcat'
```

【预期】

```
LISTEN 0 511 127.0.0.1:3001 ... users:(("node",pid=...,fd=..))     ← OneBot WS，必须回环
LISTEN 0 511 127.0.0.1:6099 ...                                     ← WebUI，必须回环
```

【失败】

- `3001` 根本没有 → OneBot 的「WebSocket 服务器」还没建（下一步 S8），或 NapCat 没起来。
- 出现 `0.0.0.0:3001` 或 `*:3001` 或 `[::]:3001` → **回 WebUI 把 host 改成 `127.0.0.1`**，
  改完再跑一次 `ss` 确认。
- 出现 `0.0.0.0:6099`（WebUI 对外）→ 立刻改绑回环或改端口。**WebUI 泄露 = 别人能接管你的 QQ**。

### 8.4 Docker 路线：本机不可用（仅留档，不在本机执行）

**本机不可用，证据**：`https://registry-1.docker.io/v2/` → **`000`**（4.202 s 超时），Docker Hub 不可达；
且 S1 已确认 `NO_DOCKER`（这台机器根本没装 Docker）。**若将来换到能访问 Docker Hub 的网络环境，可以再评估这条路线。**
这一节的用途只是：换机器/换网络时不必重做调研。

若那时真要走容器，下面 5 条**必须**满足（官方示例可能不带，要自己补）：

| # | 要求 | 为什么 |
|---|---|---|
| 1 | 端口映射**只绑回环**：`-p 127.0.0.1:3001:3001`，**反例**是 `-p 3001:3001` | 反例等于绑 `0.0.0.0`；即使安全组没开 3001，同 VPC 内也能连上你的 OneBot 端口 |
| 2 | `--restart unless-stopped` | 宿主机重启后 NapCat 自动回来 |
| 3 | 把官方 README 标明的**配置/数据目录**挂到宿主目录（如 `/opt/napcat/config`） | 不挂载 = 每次重建容器都要重新扫码登录，属于封号高发行为（见 S14） |
| 4 | 容器内 OneBot WS 服务的端口与映射端口一致（3001） | 不一致则 bridge 连不上 |
| 5 | 不要加 `--privileged`，除非官方 README 明确要求 | 少给容器权限 |

容器路线下，**扫码二维码与登录日志要用 `docker logs -f <容器名>` 看**（对应裸机路线的
`journalctl -u <napcat单元名> -f`，见 S8.1）。容器日志不会自己进宿主的 journald，`journalctl` 里什么都没有。

---

## 9. S8 NapCat 登录 + 配置 OneBot「WebSocket 服务器」

### 9.1 找到 WebUI 地址与 token

【命令】

```bash
# 裸机（本文主路径，S7 装出来的）：unit 名按实际替换
sudo journalctl -u <napcat单元名> -n 200 --no-pager | grep -iE 'webui|token|http://' | tail -20
# 容器（本机不可用，见 8.4；只有换到能访问 Docker Hub 的网络后才用这条）：<容器名> 换成 docker ps 里的名字
docker logs <容器名> 2>&1 | grep -iE 'webui|token|http://' | tail -20
```

【预期】打印出 WebUI 的地址（`http://<ip>:<port>/webui`）与一次性 token。
**端口以日志为准**，本文不写死（不同版本会变）。

### 9.2 通过 SSH 隧道看 WebUI（推荐，避免把 WebUI 露到公网）

【命令】（Windows 本机，另开一个窗口，不要关）

```powershell
ssh -N -L 127.0.0.1:6099:127.0.0.1:6099 <SSH_USER>@<SERVER_IP>
```

如果日志里端口不是 6099，把上面两个 `6099` 都换成实际端口。然后在浏览器打开
`http://127.0.0.1:6099/webui`，填入日志里的 token。

### 9.3 用**专用小号**扫码登录

手机 QQ 打开扫一扫 → 扫码 → 确认。**登录前先读 S14 的养号要求**，这一步是可逆性最差的。

【预期】WebUI 显示在线、显示号码与昵称；日志出现登录成功相关行。

【失败】提示需要设备锁/短信验证/滑块 → 按提示在手机上完成；如果反复要求验证，
**停止重试**（每次失败都增加风控权重），6 小时后再试一次。

### 9.4 配置 OneBot v11 WebSocket 服务器（本项目最关键的一步）

WebUI → **网络配置**（各版本文案略有差异）→ 新建 → 选 **WebSocket 服务器**。

> ⚠️ 必须选「**WebSocket 服务器**」（NapCat 当服务端）。如果选成「WebSocket 客户端」，
> 方向就反了：NapCat 会主动去连别人，而 bridge 也在主动连别人 —— 两端都在连，永远连不上。

| 配置项 | 必须填 | 说明 |
|---|---|---|
| Host / 监听地址 | `127.0.0.1` | 填 `0.0.0.0` 就把 OneBot 端口暴露到网卡上了 |
| Port / 端口 | `3001` | 与 env 里 `NAPCAT_WS_URL` 的端口一致 |
| Token | `<NAPCAT_TOKEN>` | **与 `/etc/dsh-qq-bridge/env` 的 `NAPCAT_ACCESS_TOKEN` 逐字符一致** |
| 消息格式 / Message format | `array` | bridge 按 `message` **段数组**解析。选 `string`（CQ 码）会导致解析失败或文本乱 |
| 启用 / Enable | 开 | 保存后确认状态为已启用 |

如果页面里有「上报自身消息 / report self message」之类选项，建议**关**（否则机器人自己说的话也会入队，
形成回环）。

保存后回到服务器验证：

【命令】

```bash
sudo ss -ltnp | grep 3001
```

【预期】`LISTEN ... 127.0.0.1:3001`。

### 9.5 手工验证 OneBot 端点真的能握手

【命令】

```bash
TOKEN='<NAPCAT_TOKEN>'
curl -sS -i -N --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:3001/  | head -6
```

【预期】第一行是 `HTTP/1.1 101 Switching Protocols`。

> 这条 curl 只带了 header 形态的 token。如果你这份 NapCat 只认 query 形态，它会返回 `401`，但
> `sudo journalctl -u dsh-qq-bridge | grep 'napcat websocket connected'` 仍然能连上 —— 那是 NapCat 侧的
> 校验方式问题，不是配置错。桥接进程**两种形态都发**（`PROTOCOL.md`「OneBot 侧约束」），所以只要日志里有
> `napcat websocket connected` 就算过。

【失败】

| 现象 | 原因 |
|---|---|
| `401` / `403` | **值**不一致。bridge 会同时用 `Authorization: Bearer` 头和 `?access_token=` 参数发同一个 token，所以别再怀疑"形式不对"：逐字符比对 `/etc/dsh-qq-bridge/env` 的 `NAPCAT_ACCESS_TOKEN` 与 NapCat 页面的 Token |
| `404` | 路径不对 → 把 NapCat 配置里的路径填进 `NAPCAT_WS_URL`（默认 `/`） |
| `Connection refused` | OneBot 服务没启用 / 端口不是 3001 |
| 连上但立刻断开 | 消息格式或路径不匹配；看 `journalctl -u dsh-qq-bridge` 的报错 |

### 9.6 备份 NapCat 配置（做一次，省很多事）

【命令】

```bash
# 路径换成你实际的配置目录（裸机看官方文档给的目录名；容器路线是宿主挂载目录，见 8.4）
sudo tar -czf /root/napcat-config-$(date +%F).tgz -C / <你的配置目录>
ls -lh /root/napcat-config-*.tgz
```

有这份备份，重装/换机时把目录放回去就能免扫码（**免扫码 = 少一次风控触发**）。

---

## 10. S9 云端自测（不依赖本机，先把云端半边钉死）

【命令】

```bash
NODE_TOKEN=$(sudo grep -m1 '^NODE_TOKEN=' /etc/dsh-qq-bridge/env | cut -d= -f2-)

systemctl status dsh-qq-bridge --no-pager | head -5
sudo ss -ltnp | grep -E '8787|3001'

echo "--- health（无鉴权，应 200） ---"
curl -sS -w '\nHTTP %{http_code}\n' http://127.0.0.1:8787/health

echo "--- 不带 token（应 401） ---"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' 'http://127.0.0.1:8787/node/poll'

echo "--- 带 token 长轮询（应 200 且 tasks 为数组） ---"
curl -sS -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer $NODE_TOKEN" \
  'http://127.0.0.1:8787/node/poll?wait=1'
```

【预期】

```
Active: active (running)
LISTEN ... 127.0.0.1:8787
LISTEN ... 127.0.0.1:3001
{"ok":true,"queued":0,"uptimeMs":...}
HTTP 200
HTTP 401
{"tasks":[]}
HTTP 200
```

【失败】

| 现象 | 原因 |
|---|---|
| health 通、`/node/poll` 401 | token 与 env 不一致（注意 `cut` 出来的值别带空格） |
| `/node/poll` 404 | 8787 上不是我们的 bridge；`sudo ss -ltnp | grep 8787` 看是哪个进程 |
| `{"tasks":[...]}` 非空 | 说明已经有消息入队了 —— 好事，接着做 S13 |
| health 超时 | bridge 没起：`journalctl -u dsh-qq-bridge -n 50 --no-pager` |

另看一条：`journalctl -u dsh-qq-bridge --since '5 min ago' --no-pager | grep -iE 'ws|websocket|napcat|connect'`
应当能看到 WS 已连上（具体文案由 bridge 实现决定，认关键字即可）。

---

## 11. S10 本机隧道（tunnel.ps1）

### 11.1 放脚本

【命令】（Windows PowerShell）

```powershell
New-Item -ItemType Directory -Force -Path C:\dshqq | Out-Null
Copy-Item "C:\Users\lenovo\Documents\deepseek-harness\default-workspace\qq-dsh\deploy\tunnel.ps1" C:\dshqq\ -Force
Copy-Item "C:\Users\lenovo\Documents\deepseek-harness\default-workspace\qq-dsh\deploy\verify.ps1" C:\dshqq\ -Force
Get-ChildItem C:\dshqq | Select-Object Name,Length
```

【预期】看到 `tunnel.ps1`、`verify.ps1` 两个文件。

### 11.2 先配 SSH 密钥（必须做，否则计划任务里没人输密码）

【命令】

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\dshqq_ed25519" -N '""' -C "dshqq-tunnel"
type "$env:USERPROFILE\.ssh\dshqq_ed25519.pub" | ssh <SSH_USER>@<SERVER_IP> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo KEY_INSTALLED"
```

【预期】第一条生成两个文件；第二条最后打印 `KEY_INSTALLED`。

【验证】

```powershell
ssh -i "$env:USERPROFILE\.ssh\dshqq_ed25519" -o BatchMode=yes <SSH_USER>@<SERVER_IP> "echo OK-$(hostname)"
```

【预期】打印 `OK-<服务器名>`（**不再问密码** = 密钥生效）。`BatchMode=yes` 的作用是：如果还要密码，
它会直接失败而不是挂在那里 —— 这就是自动化能不能跑起来的判据。

### 11.3 手动跑隧道（前台，看图）

【命令】（**两个窗口**：窗口 A 跑隧道，窗口 B 做验证）

```powershell
# 窗口 A
powershell -NoProfile -ExecutionPolicy Bypass -File C:\dshqq\tunnel.ps1 `
  -SshServer <SERVER_IP> -SshUser <SSH_USER> `
  -IdentityFile "$env:USERPROFILE\.ssh\dshqq_ed25519"
```

【预期】窗口 A 打印：

```
2026-10-24 18:00:00 [OK] 守护启动：root@47.100.x.x:22  ->  本机 127.0.0.1:8787   (ssh: C:\Windows\System32\OpenSSH\ssh.exe)
2026-10-24 18:00:00 [INFO] 日志：C:\Users\lenovo\AppData\Local\dsh-qq\tunnel.log
```

之后**没有** `[ERROR]`。窗口 B：

```powershell
curl.exe -sS http://127.0.0.1:8787/health
```

【预期】打印 `{"ok":true,...}`。**能打印出来就说明隧道通了**（这一步比任何推断都硬）。

【失败】

| 现象 | 原因 / 处置 |
|---|---|
| `[FATAL] 没给云端地址` | 忘了 `-SshServer` |
| `[ERROR] ssh 退出，退出码 255` + `Permission denied` | 密钥没生效：回 11.2 用 BatchMode 那条命令验证 |
| `[ERROR] ssh 退出，退出码 255` + `Connection refused` | 端口错或安全组没开 22 |
| `[WARN] 本机 127.0.0.1:8787 已在监听` | 已经有一个隧道/别的服务占着 8787。别重复起；要换端口就同时改 `-LocalPort` 和 node-plugin 的地址 |
| `bind: Address already in use` | 同上 |
| 一直重连、退避涨到 60s | 看 `%LOCALAPPDATA%\dsh-qq\tunnel.log` 里 `ssh:` 开头的行，那是 ssh 自己的报错原文 |

> 退避行为：1s → 2s → 4s → 8s → 16s → 32s → 60s（上限）。若上次连接**存活超过 60 秒**，
> 下次失败从 1s 重新开始 —— 避免偶发断线被慢慢拖成 60 秒的空窗。

---

## 12. S11 开机自启（计划任务）

【命令】（**以管理员身份**开 PowerShell）

```powershell
$arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\dshqq\tunnel.ps1" ' +
       '-SshServer <SERVER_IP> -SshUser <SSH_USER> ' +
       "-IdentityFile `"$env:USERPROFILE\.ssh\dshqq_ed25519`""

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName 'dsh-qq-tunnel' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'DSH QQ 桥接 SSH 隧道守护' -Force
Start-ScheduledTask -TaskName 'dsh-qq-tunnel'
Get-ScheduledTask -TaskName 'dsh-qq-tunnel' | Select-Object TaskName,State
Get-ScheduledTaskInfo -TaskName 'dsh-qq-tunnel' | Select-Object LastRunTime,LastTaskResult
```

【预期】

```
TaskName     State
dsh-qq-tunnel Running
```

`LastTaskResult` 为 `267009`（正在运行）或 `0` 都正常；`ExecutionTimeLimit=0` 表示不限期，
**否则隧道会在 3 天后被计划任务掐掉**（默认 3 天）。

【验证】注销/重启本机 → 重新登录 → 跑一次 `curl.exe -sS http://127.0.0.1:8787/health`，
能出 JSON 就说明自启生效。

【失败】

| 现象 | 原因 |
|---|---|
| `Register-ScheduledTask: Access is denied` | 没用管理员 PowerShell |
| State 一直是 `Ready` 不动 | 触发条件/动作写错：`(Get-ScheduledTask -TaskName dsh-qq-tunnel).Actions` 看实际参数 |
| 后台没起来但手动跑正常 | 计划任务里 `%USERPROFILE%` 之类不展开 → 注册时就把绝对路径写进去（上面已用展开后的 `$env:USERPROFILE`） |

停止守护：`Stop-ScheduledTask -TaskName dsh-qq-tunnel`；彻底删除：
`Unregister-ScheduledTask -TaskName dsh-qq-tunnel -Confirm:$false`。

---

## 13. S12 本机自检（verify.ps1）

【命令】

```powershell
$env:DSH_QQ_NODE_TOKEN = '<NODE_TOKEN>'
powershell -NoProfile -ExecutionPolicy Bypass -File C:\dshqq\verify.ps1
```

【预期】（`tasks 条数 = 0` 表示队列空，链路本身是通的）

```
== 1) 隧道端口 127.0.0.1:8787 是否可连
  [PASS] 端口可连。
== 2) GET /health（无鉴权，验证 bridge 活着）
  [PASS] 200 ok:true  queued=0  uptimeMs=...
== 3) GET /node/poll?wait=1（带 Bearer token，验证鉴权 + 协议）
  [PASS] 200 合法 JSON，tasks 条数 = 0
         空数组 = 队列里此刻没有新消息。链路本身是通的。
 结论：全部通过。云端 bridge + 隧道 + 鉴权 + 协议 都对上了。
```

退出码 0 = 全通过。三项检查分别对应三层故障：

| 失败在第几步 | 责任层 | 排查入口 |
|---|---|---|
| 1（端口不通） | 隧道 | S10 / `tunnel.log` |
| 2（health 非 200） | 云端 bridge 进程 | 服务器 `systemctl status dsh-qq-bridge` |
| 3（401 或非 JSON） | token / 协议 | S5 的 env、S9 的 curl |

§注意：第 3 步会真的取走一个任务（进入 `delivering`，租约 120 秒）。如果 node-plugin 没在跑，
120 秒后租约过期、任务回到 `queued`，**不会丢**。所以用 verify 做联调探针是安全的。

---

## 14. S13 端到端联调（云端半边可以单独验收）

### 14.1 私聊入队（最小闭环）

1. 用 `<OWNER_QQ>` 那个号给小号发一条私聊：`ping`
2. 本机跑 `verify.ps1`

【预期】`tasks 条数 = 1`，并且

```
[PASS] Task 字段齐全 taskId=... kind=private userId=<OWNER_QQ> isOwner=True images=0 text='ping'
```

**这一条同时证明了**：NapCat 登录成功 → OneBot 事件上报 → bridge 解析/入队 → 限流通过 →
鉴权与协议正确 → 隧道通 → 本机能取。云端半边的整条链路到此为止全部验完。

### 14.2 群消息只认 @

1. 把机器人小号拉进一个群 —— 能不能拉群**按 §15.1 的档位定，不是一律禁止**：
   - **A 档（活跃号，当前用户）**：跳过养号期，**当天部署完就可以拉群测这一条**。
     群里的被动应答（`@小号` 后回一句）不算主动发言，符合 §15.1.3 的 P0「只收不发」。
   - **B 档（新号 / 休眠号）**：按 §15.1.1 做满 14 天养号期（期间不接任何协议端），
     养号期满、走完收敛期再拉群做这一步。
2. 群里发一条**不 @** 小号的消息 → 跑 `verify.ps1` → 【预期】`tasks 条数 = 0`
3. 群里 `@小号 在吗` → 跑 `verify.ps1` → 【预期】`kind=group`，`groupId` 有值，`text` 里不带 `@小号`

### 14.3 限流

1. 一分钟内连发 7 条私聊
2. 跑 `verify.ps1` → 【预期】最多 6 条入队，第 7 条被丢弃
3. 机器人应回一句限流提示；5 分钟内再触发限流**不会**再提示（防刷屏）

### 14.4 过期丢弃（可选，费时）

把 `BACKLOG_TTL_MS` 临时改成 `60000` → `systemctl restart dsh-qq-bridge` → 发一条消息 →
等 61 秒 → 跑 `verify.ps1`。
【预期】`tasks 条数 = 0`，且机器人给 `replyTarget` 回了固定文案：
「这条消息发出时我不在线，已经跳过了。有事再发一次。」
测完把 `BACKLOG_TTL_MS` 改回 `1800000` 并重启。

### 14.5 全部打通（等 T2 就位后）

node-plugin 装好并挂在 DSH `qq` profile 上之后：发消息 → 本机 agent 跑一轮 → 回复发回 QQ。
在此之前，`verify.ps1` 取到的任务会因为没人处理而在 120 秒后被重新投递，这是**预期行为**。

---

## 15. S14 降风控清单（照做，不要"注意安全"式的自我安慰）

**前提认清**：专用小号 + 机房 IP + 长期在线协议端，这是 QQ 风控的典型画像。做了下面这些**只是降低概率，
不能消除**封号风险。真正的防护是"这个号丢了你不心疼"。

### 15.1 先分档：养号期还欠不欠，看的是这个号的**近期行为**，不是注册时长

风控看的是近期行为的连续性，不是账号年龄。先按下面这张表定位自己，再决定跳过还是补做。

| 档 | 判据（全部满足才算） | 你要做的事 |
|---|---|---|
| **A 档 · 活跃号** | ① 同一个号**近 14 天**几乎每天在手机端有真实收发；② 此刻还正常登录在手机上；③ 只在**一台**手机、**一个**常用网络上用 | **跳过养号期**，直接进部署（S7/S8 照做），但从挂上 NapCat 那一刻起按 **15.1.3 收敛期**走 |
| **B 档 · 新号 / 休眠号** | 任一条成立：注册 **< 14 天**；近 14 天没正常用过（长期不登、只在网页或协议端挂过）；换过绑或被风控提醒过 | 先按 **15.1.1 养号期**做满 **14 天**（建议 21 天），**期间不接任何协议端** |

**当前用户走 A 档。** 小号注册约一年、手机上一直在用 —— 对它执行"再养 14–21 天"是纯粹的时间浪费，
等于停在那里三周什么也干不了。所以：**跳过养号、直接部署**，改用 15.1.3 的收敛期去稀释
"机房 IP 长期在线"这一项风险（`DECISIONS.md` D15）。

判据边界（拿不准就按 B 档走，多花 14 天远好过封号）：

- 只看**近 14 天有没有真人在手机上用**，不看注册多久。"注册一年但从没正常用过"算 **B 档**。
- A 档只免掉"唤醒"这一环，**不免收敛期**。第 1 天就按 15.2 全量跑 = 主动踩雷。
- 手机在家宽 ↔ 4G 之间换网不算异地；但 A 档部署当天起，**服务器公网 IP 定下来就不能再变**（见 15.4）。

#### 15.1.1 B 档 · 养号期（新号 / 休眠号，最重要，别跳过）

| 项 | 要求 |
|---|---|
| 时长 | **14 天**手机端正常使用，**建议 21 天**。期间**不接任何协议端**（先别装 NapCat） |
| 登录方式 | 只用**一台**手机、**一个**常用网络（家里 Wi-Fi 或手机 4G/5G） |
| 行为 | 每天主动发 3–10 条真实对话：私聊熟人、进 1–2 个正常群聊天 |
| 每日消息量 | **≤ 50 条/天**（收发合计） |
| 好友数 | 养号期加 **5–10 个**真实好友（纯新号零好友最容易被打标） |
| 头像/资料 | **第 1 天就一次性设好**，之后 30 天内不再改（改资料是风控高权重事件） |
| 实名/绑定 | 绑手机号；能开设备锁就在手机上开（但见 15.4：协议端会被设备锁拦，二者冲突时以"能用"为准） |

**退回 A 档的判据**：同一个号在**同一常用网络**上、手机端**正常使用满 14 天以上**（每天有真实收发、
无风控提醒、无异地登录短信）。满足后按 A 档进部署 —— 但**照样要过 15.1.3 的收敛期**，
养号只负责"唤醒"，不替代收敛。

#### 15.1.2 一行速查

- 一年老号、天天在手机上聊 → **A 档** → 今天就能装 NapCat，前 14 天只收不发（15.1.3）。
- 刚注册 / 放了大半年没动 / 刚被提醒过 → **B 档** → 手机端先养 14 天，期间别碰协议端（15.1.1）。

#### 15.1.3 A 档收敛期（当前用户从挂上 NapCat 的第 1 天起就按这张表走）

「只收不发」的精确定义：机器人**只应答别人发来的消息**，不主动发起任何会话 —— 不主动私聊、
不在群里起话题、不发广播/推送、不 @ 任何人、不额外发表情包和图片刷存在感。有人问它才答，
没人说话它一个字都不发。

| 阶段 | 天数（自挂上 NapCat 起算） | 主动发送 | 每日消息量（收发合计） | 触发条件（进入下一阶段） |
|---|---|---|---|---|
| **P0 · 只收不发** | 第 **1–14** 天 | **0 条**（仅被动应答；应答本身仍受 15.2 的 `≥20 秒/条`、`≤6 条/分钟`、`≤100 条/群/天` 约束） | **≤ 50 条/天**（与 B 档养号期同量级） | 满 14 天，且期间**没有**出现过 15.5 的任何一个信号 |
| **P1 · 放开到 1/3 量** | 第 **15–30** 天 | 仍为 **0 条**（15.2 里的"主动推送"到 P2 才解禁） | **≤ 100 条/天**（= 15.2 的 300 条 × 1/3） | 满 30 天，且期间没有出现过 15.5 的信号，且**没有换过服务器公网 IP** |
| **P2 · 全量** | 第 **31** 天起 | 按 **15.2**：主动推送 ≤ 1 次/小时、同群 ≤ 3 次/天；**主动私聊陌生人恒为 0** | **≤ 300 条/天** | 无 —— 此后长期按 15.2 运行 |

退化规则（比上表更重要）：**任何一天命中 15.5 的信号 → 立刻停协议端、退回 P0**，不是"先观察看看"。
回退后必须**连续 14 天**无信号，才能重新往上走一档。

落地怎么保证"只收不发"：v1 的 bridge **没有主动推送入口**，消息只能由 QQ 侧入队驱动 ——
所以只要你别自己加 cron、别写定时群发脚本，这条自动成立。想主动发，等 P2。

【命令】（P0/P1 期间随时可查，核对出站量有没有偷偷超出）

```bash
sudo journalctl -u dsh-qq-bridge --since '14 days ago' | grep -c '"msg":"task enqueued"'
```

【预期】这个数量应当**不超过**同期你在 QQ 上真正收到的（含 @ 的）消息条数。明显多于你亲眼看到的来信数，
说明有东西替你"主动发消息"了（定时脚本、广播任务）→ **立刻关掉**。

【失败】`grep -c` 返回 `0` 但 QQ 侧明明有消息 → 说明消息没进 bridge（看 S8 的 WS 连接），
不是"没有主动发送"的证明，别当成通过。

### 15.2 出栏后的运行指标

这张表是**全量放开之后**的状态（A 档 = 第 31 天起；B 档 = 养号期 + 收敛期都走完之后）。
收敛期内的量按 15.1.3 的 P0/P1 打折，**不要**在这里取数。

| 项 | 上限 |
|---|---|
| 每日消息量 | **≤ 300 条/天**（收发合计），含机器人回复 |
| 单群发言频率 | **≥ 20 秒/条**；同一分钟 **≤ 6 条**（与 bridge 侧限流一致，别绕过它） |
| 单群每日 | **≤ 100 条** |
| 入群数 | **≤ 5 个群**（前 30 天 ≤ 3 个） |
| 主动私聊陌生人 | **0 次**。机器人只在被私聊时回 |
| 主动推送（广播类） | **≤ 1 次/小时**，同一群 **≤ 3 次/天**（这是最容易被举报的行为，越少越好） |

### 15.3 绝对不要做的事（每一条都是封号高危）

1. **主动加好友 / 主动拉群 / 拉人进群**（自动化加好友 = 营销号特征，最容易被秒封）
2. **改昵称、头像、签名、性别、生日** —— 尤其是"登录后立刻改"
3. **改密码、换绑手机号**
4. **@全体成员**
5. **群发相同文本**（同一条内容发给 3 个以上目标）
6. **发外链、发文件、发图片里的二维码、发"加微信"类话术**
7. **异地登录**：24 小时内不要在两地（如公司/家）切换登录 IP
8. **多设备同时在线**：手机 + 协议端之外，不要再登录平板/网页 QQ
9. **频繁重启协议端**：24 小时内 **≤ 3 次**；不要写"每分钟检查一次、挂了就重启"的脚本
10. **24 小时内删除并重装 NapCat / 换容器镜像**（每次都是新设备指纹）
11. 用**境外 IP / 代理 / VPN** 登录（机房 IP 已经不是"家宽"，别再叠一层）
12. 登录后立刻大量收发（按 15.1.3 的收敛期走：P0/P1 期间 **0 条主动发送**，日量按 P0 的 50 / P1 的 100 卡）

### 15.4 IP 稳定性

| 项 | 做法 |
|---|---|
| IP 固定 | 用 **EIP（弹性公网 IP）** 绑在这台 ECS 上，不要"换区重建实例"（换 IP = 异地登录） |
| 不要挂代理 | NapCat 直连，不要给它套 HTTP 代理/SOCKS |
| 不要换网络 | 服务器网卡、路由、安全组随便调，但**公网 IP 一个都别变** |
| 迁移服务器 | 如果必须换机换 IP：先在手机上正常登录该号 3 天，再上协议端；不要"服务器搬完立刻重启协议端" |
| 时区/时间 | 服务器 `timedatectl set-ntp true`，时间偏差 >1 分钟会显著提高风控命中 |

### 15.5 风控命中自查信号 + 掉线 / 重连策略（写死在脑子里）

**核心原则一句话**：发现信号的第一动作是**立刻停掉协议端止损，不是重试** —— **每次重试都在加权重**。

**一、自查信号 → 第一动作**（在手机上就能看到，不用等日志）

| 信号 | 第一动作 |
|---|---|
| 登录 QQ 要**额外验证 / 滑块 / 短信验证码** | 停协议端 **6–24 小时**；手机上正常用一会儿再试，**不要连点重试** |
| 消息**发不出去**，提示"发送失败"或"账号异常" | 立即停协议端，手机端登录自查；能正常聊天了也再等 24 小时才恢复 |
| 被要求**改密码** | 立即停协议端。改完等 **48 小时**再重连（改密码本身是高权重事件，见 15.3 第 3 条） |
| **QQ 安全中心**发来提醒 / "异地登录"短信 | 立即停协议端 **24 小时**，这是最后一级警告。别连着重连、别反复验证 |
| 协议端**反复掉线**（登录后几分钟一掉，连着好几轮） | 停 **6 小时**，再按下面"二"的退避走；**不要**写"挂了就自动重启"的脚本 |
| 同一条消息**本地成功、对方没收到**（日志 `ok:true`，对方说没看到） | 视为被静默拦截：立刻停协议端，24 小时内不再发任何消息 |
| 手机端被**莫名踢下线** / 突然要重新登录 | 停协议端 6–24 小时；除手机 + 协议端外不要再登第三个客户端 |
| 好友问"你这号是不是被盗了" / 群里看不到它说话 | 同上：先停，再查 15.3 有没有被违反过 |

**二、掉线 / 重连处置**（信号出现后具体怎么退避）

| 现象 | 处置 |
|---|---|
| NapCat 进程挂了 | **不要立刻重启**。等 **60 秒**再起一次。一天内重启累计 ≤ 3 次 |
| 连续 3 次起不来 | 停手，退避 **5 分钟 → 15 分钟 → 60 分钟**，仍失败就**隔天再看** |
| 登录后马上掉线、反复掉 | 大概率被风控盯上：**停 6 小时**，手机上手动登录一次看看是否正常 |
| 要求短信/滑块/设备验证 | **立刻停止一切重试**，停止 6–24 小时，用手机端正常使用一会儿再试 |
| 消息发不出去 / 提示"账号异常" | **立即停协议端**，手机端登录检查，别硬试 |
| QQ 安全中心发来提醒 | **立即停协议端 24 小时**，这是最后一级警告 |

周期性检查（每周一次，5 分钟）：

1. 手机 QQ → 设置 → 账号安全 → **登录设备管理**：有没有你不认识的设备
2. 是否有"异地登录"短信/提醒
3. `journalctl -u dsh-qq-bridge --since '7 days ago' | grep -ciE 'fail|error|401'` 异常数量趋势
4. NapCat 是否被无谓重启过（`systemctl show -p ActiveEnterTimestamp <你的napcat单元名>`，时间是否比上次检查新得多）

### 15.6 一句话总结

**A 档（当前用户）直接部署，前 14 天只收不发**；B 档先养 14 天、再过同一张收敛期表。
之后**只做被动回复、不主动社交、不改资料、不换 IP、不频繁重启**。
想让它像人，就让它**安静**。

---

## 16. S15 故障排查表

| 症状 | 先跑这条 | 判断 |
|---|---|---|
| 本机 `verify.ps1` 第 1 步失败 | 服务器：`curl -sS http://127.0.0.1:8787/health` | 服务器通 → 隧道问题（S10）；服务器也不通 → bridge 问题（S6） |
| 本机第 2 步失败但第 1 步通过 | `sudo ss -ltnp \| grep 8787` | 8787 上是别的进程 → 停掉或改端口 |
| 本机第 3 步 401 | `sudo grep '^NODE_TOKEN=' /etc/dsh-qq-bridge/env` | 逐字符比对；注意别带上行尾空格/引号 |
| 任务取不到（tasks 一直空） | 服务器：`journalctl -u dsh-qq-bridge -n 100 \| grep -iE 'ws\|napcat\|connect'` | 看是否 WS 未连接（S8 配置错） |
| 任务入队但报错 | 上面同一条日志 | 看 bridge 的错误行，先解决 token/格式 |
| 收到消息但不回复 | 本机 node-plugin | 属 T2 范围（见附录 B），不是部署问题 |
| 回复重复发送 | `PROTOCOL.md` 幂等段 | 重复 `POST /node/result` 应被忽略并返回 `duplicate:true` |
| NapCat 频繁掉线 | S14 15.5 | 别急着重启，先按退避来 |
| 磁盘涨得快 | `du -sh /var/lib/dsh-qq-bridge/*` | `blobs/` 里是图片；清理由 T1 的保留策略负责，检查 `queue.db` 是否在膨胀 |
| 隧道每天断一次 | `tunnel.log` 里 `ssh:` 行 | 常见是网络抖动；`ServerAliveInterval=30` 已在用，属正常恢复 |

---

## 17. S16 日常运维

【常用命令】

```bash
# 日志（跟）
sudo journalctl -u dsh-qq-bridge -f
# 最近 100 行
sudo journalctl -u dsh-qq-bridge -n 100 --no-pager
# 清日志到 14 天
sudo journalctl --vacuum-time=14d

# 重启（改了 env 必须重启才生效）
sudo systemctl restart dsh-qq-bridge
sudo systemctl status dsh-qq-bridge --no-pager | head -5

# 升级 bridge：重跑 S4 上传 + 解包，然后
sudo systemctl restart dsh-qq-bridge

# 备份数据（先停，避免 sqlite 写到一半）
sudo systemctl stop dsh-qq-bridge
sudo tar -czf /root/dshqq-data-$(date +%F).tgz -C /var/lib dsh-qq-bridge
sudo systemctl start dsh-qq-bridge
ls -lh /root/dshqq-data-*.tgz

# 轮换 NODE_TOKEN
sudo sed -i 's/^NODE_TOKEN=.*/NODE_TOKEN=<新token>/' /etc/dsh-qq-bridge/env
sudo systemctl restart dsh-qq-bridge
# 本机同步：改 DSH_QQ_NODE_TOKEN，重跑 verify.ps1

# 完全卸载
sudo systemctl disable --now dsh-qq-bridge
sudo rm -f /etc/systemd/system/dsh-qq-bridge.service
sudo systemctl daemon-reload
sudo rm -rf /opt/dsh-qq-bridge /var/lib/dsh-qq-bridge /etc/dsh-qq-bridge
sudo userdel dshqq 2>/dev/null || true
```

---

## 18. S17 未验证项与边界声明（请务必读）

**我在本机实测过的**（附证据在交付回报里）：

- `tunnel.ps1` / `verify.ps1` 通过 PowerShell 5.1 语法检查。
- `verify.ps1` 三条路径实跑：全通过（exit 0）、401 鉴权失败（exit 1）、隧道不通（exit 1，给出处置话术）。
  用的是本机临时搭的 HTTP 桩（127.0.0.1:8787），**不是真 bridge**。
- `tunnel.ps1` 实跑：端口被占用时不重复建隧道；ssh 拒连时退出码 255 被记录、退避 1s→2s→4s 递增。

**我无法验证、只能由你执行的**：

| 项 | 原因 |
|---|---|
| 云端每条命令的真实执行结果 | 我没有那台机器的访问权 |
| **S3 那段 npmmirror 安装脚本的真实执行结果** | 我只有 Windows 本机（无 bash、无 WSL、无那台服务器），**该脚本在本机一个字都没跑过**。它的可靠性来自两处，不是来自实测：①命令由人工逐字核对固定；②第 2 步的 `SHASUMS256.txt` 校验。跑的时候若校验不过，按 4.2 的规则停下，不要跳过 |
| S1.2 那 5 条 `curl` 数字 | 是**服务器上实测**后交给我的原始值，我无法在本机复现（本机无外网）；表格只是如实转写，未二次加工 |
| NapCat 安装器的实际行为 | 写文档的本机无外网，抓不到页面正文；服务器侧连通性已实测（S1.2），但"页面里的命令"仍要你到官方页面复制（S0.2） |
| NapCat 实际登录、真实 QQ 收发 | 需要你的号与手机 |
| `systemd-analyze verify` 的实际输出 | 本机是 Windows，没有 systemd |
| 真实封号风险与风控阈值 | 无法量化；S14 是降低概率的经验规则，不是保证 |
| bridge 与 node-plugin 的真实联调 | 属 T1/T2 交付范围 |

**契约裁决与待验证项（需要调度者知道的）**：

1. 已裁决，见 `PROTOCOL.md`『OneBot 侧约束』（`NAPCAT_WS_URL` 路径、access_token 双通道）。
   路径用 URL 解析器原样带进 WS upgrade（结尾 `/` 填不填都能连上）；access_token **同时**用
   `Authorization: Bearer` 头和 `?access_token=` 查询参数发送（为空时两者都不发）。按此执行即可，
   不必再按本文旧版猜测"值一致却连不上"，也不必为路径结尾 `/` 做特殊处理。
2. **待验证项**（不是契约矛盾）：bridge 是否真实现了 `BRIDGE_HOST=0.0.0.0` 时拒绝启动，
   由调度者复审 bridge 代码时验证。在此之前把安全组也作为一层保险，**不要只依赖 bridge 自检** ——
   8787 不能在安全组上对 `0.0.0.0/0` 开放。
3. **带宽上限（用户可感知，不是故障）**：这台机器出网带宽 5 Mbps，折算约 625 KB/s（5 ÷ 8）。
   文本消息完全无感；但图片要经 SSH 隧道从云端传到本机，一张 2 MB 的图约需 3 秒，连发多张会明显变慢。
   若体验不可接受，可升带宽，或改成只传缩略图。**这只是告知，不改代码设计。**

---

## 附录 A · env 键与部署契约逐条对照

`PLAN.md`「部署契约」列出 9 个**必需**键，`env.example` 与 `dsh-qq-bridge.service`（`EnvironmentFile=`）与之一致：

| # | 键 | `env.example` 中的值 | 谁读它 | 改错的后果 |
|---|---|---|---|---|
| 1 | `NAPCAT_WS_URL` | `ws://127.0.0.1:3001/` | bridge（WS 客户端） | 连不上 NapCat；路径错 → 404 |
| 2 | `NAPCAT_ACCESS_TOKEN` | `REPLACE_WITH_NAPCAT_TOKEN` | bridge | 与 NapCat 不一致 → 401 |
| 3 | `BRIDGE_HOST` | `127.0.0.1` | bridge | 改 `0.0.0.0` 应拒绝启动；别试 |
| 4 | `BRIDGE_PORT` | `8787` | bridge | 与隧道 `-L` 的端口不一致 → verify 第 1 步通但第 2 步 404 |
| 5 | `NODE_TOKEN` | `REPLACE_WITH_NODE_TOKEN` | bridge + node-plugin | 不一致 → 401 |
| 6 | `OWNER_QQ` | `1000000000` | bridge（判 `isOwner`） | 填错 → 你自己也被当非 owner（无工具） |
| 7 | `BACKLOG_TTL_MS` | `1800000` | bridge | 调小 → 消息更容易过期 |
| 8 | `DB_PATH` | `/var/lib/dsh-qq-bridge/queue.db` | bridge | 指到不可写目录 → 启动即 EACCES |
| 9 | `BLOB_DIR` | `/var/lib/dsh-qq-bridge/blobs` | bridge | 同上；图片下载会失败 |

### 可选键（不写就走默认，2026-11 之后的线上实际还多了这些）

| 键 | 默认 | 作用 |
|---|---|---|
| `INBOUND_SILENT_MS` | `180000` | NapCat 一条入站帧都没有多久就喊一声「我这边好像收不到消息了」。阈值必须远大于 NapCat 30 秒的心跳间隔 |
| `QQ_FILE_ROOTS` | `/var/lib/dsh-qq-agent/workspace:/tmp` | `/node/send_file` 肯打开哪些目录，分隔符跟平台走（`:` / `;`） |
| `PROACTIVE_ENABLED` / `PROACTIVE_MIN_GAP_MS` / `PROACTIVE_MAX_PER_DAY` / `PROACTIVE_MAX_ASKS_PER_DAY` | `false` / `10800000` / `30` / `8` | 主动开口的开关与两个额度；线上设成 `4` / `4` |
| `PROACTIVE_SPREAD_OVER_DAY` | `on` | 把每日额度按钟点摊开（19:00 前最多 3 条），免得一上午烧光、晚上一句没有 |
| `PROACTIVE_REQUIRE_ACTIVITY` | `on` | 上一次主动开口之后他一句话都没有，就别再开口 |
| `WORLD_LIFE_*` | 关闭 | 世界线（`life-feed.jsonl`）驱动的主动开口，另有独立日上限 |
| `ASR_*` / `TTS_*` | 本地 faster-whisper / 无语音 | 语音转写与合成；云端优先走 dashscope，本地脚本兜底 |

自查（**只数必需键，不要数总行数**——线上现在一共 47 行，含 ASR/TTS/主动开口/世界线）：
`for k in NAPCAT_WS_URL NAPCAT_ACCESS_TOKEN BRIDGE_HOST BRIDGE_PORT NODE_TOKEN OWNER_QQ BACKLOG_TTL_MS DB_PATH BLOB_DIR; do grep -q "^$k=" /etc/dsh-qq-bridge/env || echo "缺 $k"; done`

## 附录 B · 本机 node-plugin 对接须知（属 T2）

- 本机插件直接访问 `http://127.0.0.1:8787`（就是隧道的本机端），**不需要知道服务器 IP**。
- 鉴权头：`Authorization: Bearer <NODE_TOKEN>`，与云端 env 里那一个值逐字符一致。
- 会话键：`qq:${kind}:${groupId ?? '-'}:${userId}`；同键串行；全局并发上限 2（`maxConcurrentTurns`）；单轮超时默认 180 s、线上 profile 设 240 s（`turnTimeoutMs`）；闲置 6 小时回收会话（`idleRecycleMs`）。
- 另外两个轮转：攒满 60 轮换一个新会话、他隔 10 分钟以上再开口也换（`sessionMaxTurns` / `sessionRotateAfterIdleMs`）。会话越老不会越慢，这两条是为了别让上下文无限长。
- 非 owner 必须走**无工具** preset（硬需求，不是"尽力"）。
- 插件装好后，`verify.ps1` 第 3 步取到的任务会被真正消费，`tasks 条数` 通常保持 0 —— 这是正常的。
  想单独验云端链路时，先把 node-plugin 停掉再跑 `verify.ps1`。
