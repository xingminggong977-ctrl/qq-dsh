# qq-dsh

**Turn a QQ account into a long-running personal agent.**

Messages arrive through NapCat, a small bridge queues them, an agent runs a turn, and the
bridge sends the reply back. On top of that plain loop it grows the things that make a
chatbot feel like a resident: long-term memory with decay, a diary, a nightly review,
occasional proactive pings, and a set of narrow tools (reminders, files, a desktop bridge,
Bilibili).

It is built to be picked up by someone who has never deployed a bot before: every step has
a script, every failure mode I hit has a paragraph in [`RUNBOOK.md`](RUNBOOK.md), and every
seam has a test you can run before you trust it.

```
QQ ──> NapCat ──ws──> bridge ──queue(SQLite)──> node-plugin ──turn──> DSH agent
                            │                                          │
                            └──────── /node/result <───────────────────┘
```

The bridge owns the network, the queue, the rate limits, the timeouts and the sending.
The plugin owns the model turns, the prompt assembly and the memory. They talk over HTTP
described in [`PROTOCOL.md`](PROTOCOL.md) — so you can replace either half.

## Which repository do I need?

| Repository | What it is | Do you need it? |
| --- | --- | --- |
| [`qq-dsh-bridge`](https://github.com/xingminggong977-ctrl/qq-dsh-bridge) | NapCat WebSocket, SQLite task queue, dispatch, voice / image / file replies, reminders, proactive pings, silence watchdog | yes |
| [`qq-dsh-node-plugin`](https://github.com/xingminggong977-ctrl/qq-dsh-node-plugin) | The `qq-node` plugin: polling, turns, persona + memory budgets, tools, nightly review | yes |
| [`qq-dsh-pc-agent`](https://github.com/xingminggong977-ctrl/qq-dsh-pc-agent) | Small service on your desktop, the other end of `pc_exec` / `pc_read` / `pc_write` | only if you want it to reach your computer |
| [`qq-dsh-bili-plugin`](https://github.com/xingminggong977-ctrl/qq-dsh-bili-plugin) | `bili_search` and `bili_extract` — search videos, read transcripts, look at keyframes | optional |
| [`qq-dsh-nightly`](https://github.com/xingminggong977-ctrl/qq-dsh-nightly) | Nightly pass: a day of chat becomes a digest, the digest becomes small proposals | optional |
| this repo | Docs, protocol, decision log, deploy scripts | yes, for reference |

## Quick start

You need: a Linux box (Ubuntu 22.04+, 2 GB RAM is enough), Node 22+, one QQ account you can
log into with NapCat, and a DSH install. Roughly 20 minutes, most of it waiting on downloads.

```bash
# 1. NapCat (logs the QQ account in and exposes a WebSocket)
#    follow https://napcat.napneko.icu/ and set network.websocketServers[0].port = 3001

# 2. the bridge
git clone https://github.com/xingminggong977-ctrl/qq-dsh-bridge /opt/qq-dsh-bridge
cd /opt/qq-dsh-bridge && npm ci && npm test          # 251 tests, no network needed

# 3. the plugin, next to its persona directory
git clone https://github.com/xingminggong977-ctrl/qq-dsh-node-plugin /opt/qq-dsh
ln -s /opt/qq-dsh/node-plugin /opt/dsh-qq-agent/node-plugin   # or: "qq-node": "link:..."

# 4. secrets live outside the repo
install -d /etc/dsh-qq-bridge
#   NAPCAT_WS_URL, NAPCAT_ACCESS_TOKEN, BRIDGE_PORT, NODE_TOKEN, OWNER_QQ, DB_PATH …
#   full list and every optional knob: deploy/README.md

# 5. run it
node bin/bridge.js                                   # or: systemctl start dsh-qq-bridge
```

Then write your own `persona/PERSONA.md` (there is a template in the plugin repository) and
say hello. `MEMORY.md`, `CORRECTIONS.md` and `diary/` create themselves on first write.

Nothing in the repositories is a credential: every secret is read from
`/etc/dsh-qq-bridge/env` and `/etc/dsh-qq-agent/env`.

## If it feels slow

Chat turns took 3.6 s at the median and 180 s at the tail. Three mechanisms fixed most of the
bad feeling, and each one was added only after the logs proved the problem:

1. **The queue is not the model.** A task that is still waiting for a slot says "still on the
   previous one" instead of "thinking" — 187 s of queueing used to be disguised as thinking.
2. **Speak as soon as you have a whole sentence.** At 25 s, if the turn has already produced a
   complete sentence, it is sent immediately; the canned "still working" ladder then shuts up
   for that task.
3. **A timeout is not silence.** Hitting the wall triggers a one-line wrap-up ("where are you,
   where is the file, what is left"). If even that fails, whatever was already said is kept.

The measurements behind these are in [`docs/latency-profile-2026-11-01.md`](docs/latency-profile-2026-11-01.md).

## Memory, briefly

Facts carry a tier (`identity` / `rule` / `event` / `note` / `ops`). Identity and rules never
decay; everything else fades on `exp(-days / stability)` and is archived rather than deleted —
`recall` can still fetch it. The important correction: **being injected into the prompt is not
a rehearsal.** Early versions counted every prompt assembly as a review, which inflated the
stability of every item 32× and made forgetting impossible.

## Docs

- [`PROTOCOL.md`](PROTOCOL.md) — the HTTP contract between plugin and bridge.
- [`RUNBOOK.md`](RUNBOOK.md) — installation, migration, and one section per failure I have met.
- [`DECISIONS.md`](DECISIONS.md) — a month of trade-offs, with the logs that forced them.
- [`docs/`](docs/) — latency profile, voice registry, pc bridge protocol, nightly contract.

## 中文

这个仓库只放文档、协议、决策记录和部署脚本，代码在五个子仓库里（见上表）。
照着 `RUNBOOK.md` 从上往下做就能装起来；`DECISIONS.md` 记的是这一个月每个取舍的理由。
记忆、日记、人格这些运行时数据不在仓库里——它们活在部署机上的 `persona/` 目录。

## License

MIT.
