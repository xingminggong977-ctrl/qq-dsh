# qq-dsh

把一个 QQ 号接成 DSH 的常驻会话界面：NapCat 收消息 → 桥接排队 → DSH 跑回合 → 桥接回话。
它自己带记忆、日记、夜班和主动开口，不依赖任何云端人格服务。

这个仓库只放**文档、协议、部署脚本和决策记录**。代码在旁边的几个仓库里：

| 仓库 | 是什么 |
| --- | --- |
| `qq-dsh-bridge` | 桥接进程：NapCat WebSocket、任务队列（SQLite）、分发、语音/图片/文件、提醒、主动开口、静默看门狗 |
| `qq-dsh-node-plugin` | `qq-node` 插件：轮询桥接、跑回合、装配 persona 与记忆预算、工具（remember / recall / remind / qq_send_file / qzone_send / pc_*）、夜班 |
| `qq-dsh-pc-agent` | 主人电脑上的小服务：`pc_exec` / `pc_read` / `pc_write` 的另一头 |
| `qq-dsh-bili-plugin` | `bili_search` 与 `bili_extract` |
| `qq-dsh-nightly` | 夜班：把一天的会话压成 digest，再从 digest 里提提案 |

## 一条消息怎么走

```
QQ ──> NapCat ──ws──> bridge ──queue(SQLite)──> node-plugin ──回合──> DSH agent
                                     │                                  │
                                     └──── /node/result <───────────────┘
```

桥接不直接调模型：它只管排队、限流、超时、垫话和发送。插件不管网络：它只轮询任务、
跑回合、把结果 POST 回去。两边靠 `PROTOCOL.md` 里的 HTTP 契约说话。

慢回合在这条链上有三层兜底，全都在有真实证据之后才加：

1. **22 / 90 / 180 秒垫话**——但排队时说「前面那条我还在弄」，只有真在跑才说「在呢，我想一下」。
2. **她自己开口就先安静**——插件把说到一半的那句完整话通过 `/node/send` 先发出去，
   桥接收到带 `taskId` 的早发就撤掉罐头垫话（`markSpoke`）。
3. **撞墙不等于没说话**——超时或工具预算用尽时，先追一句「现在做到哪一步」，
   拿不到就把已经说出口的话留下，并回一句「回一句继续」。

## 文档

- [`PROTOCOL.md`](PROTOCOL.md) —— 插件 ↔ 桥接的 HTTP 契约（字段、错误码、幂等）。
- [`DECISIONS.md`](DECISIONS.md) —— 从第一天到现在的取舍记录，含每次踩坑的真实日志。
- [`PLAN.md`](PLAN.md) —— 当前进度与下一步。
- [`docs/`](docs/) —— 部署 runbook、迁移手册、协议细化、延迟画像、语音登记簿。

## 部署

`deploy/` 里是真正在跑的东西：`deploy-bridge.sh` / `deploy-node-plugin.sh`（先跑测试再重启、
重启前检查有没有未结算的回合）、systemd 单元、定时器、cron 文件、健康检查与备份脚本。

`RUNBOOK.md` 是照着做就能从零装起来的那一份。所有密钥都从 `/etc/dsh-qq-bridge/env` 和
`/etc/dsh-qq-agent/env` 读，仓库里没有任何凭据。

## 许可

MIT。
