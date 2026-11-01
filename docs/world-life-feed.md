# 她的世界事件流（life-feed）

她在 Minecraft 里过日子，聊天那边却看不见——`xiaod-thoughts.md`、`survival-notes.md` 只写给人看。
这层就是给她和聊天之间接一根只读的管子：**世界里发生了什么**，写成一列 JSON 行，聊天侧自己挑要不要当由头。

## 契约

| 项 | 值 |
| --- | --- |
| 路径 | `/opt/whale-craft/life-feed.jsonl`（`WORLD_LIFE_FILE` 可覆盖） |
| 格式 | 一行一个 JSON，追加写，永不改写历史行 |
| 权限 | `root:root 644`，目录 755 —— 聊天侧以 `dshqq` 读，只能读 |
| 时区 | `ts` 一律 ISO（带 Z），本地时区只用于说话 |

一行长这样：

```json
{"ts":"2026-10-28T13:25:13.579Z","kind":"companion","text":"天黑了，先把小尾巴叫到身边再躲夜，不把它一个人丢在外面","notable":true}
```

## kind 与 notable

| kind | 谁写 | 例子 | notable |
| --- | --- | --- | --- |
| `first` | survival / home | 第一次挖到铁、第一次被苦力怕炸死 | ✓ |
| `build` | home | 盖好了 7x7x4 的慢屋，坐标 (-185,68,76) | ✓ |
| `death` | survival | 淹死在 (-168, 55, -20)，东西掉在原地 | ✓ |
| `companion` | survival | 天黑了，先把小尾巴叫到身边 | ✓ |
| `unstuck` | survival | 卡住了，自己爬到岸边 | ✗ |
| `explore` | survival | 走了 300 格，周围是 oak_log、grass_block | ✗ |
| `thought` | thoughts.cjs | 她自言自语的第一句（每 10 分钟一次） | ✗ |

**只有 notable 才会被当成开口的由头。** 这条线是刻意的：`thought` 一天约 144 条、`explore` 在探索模式下一小时能刷满，
放进来会让「主动开口」退化成刷屏。

## 三处代码

| 位置 | 作用 |
| --- | --- |
| `whale-craft/life.cjs` | 唯一的写方：`note(kind, text)`，`KINDS`/`NOTABLE_KINDS` 是白名单，写失败只打日志 |
| `bridge/src/world-life.js` | 读方之一：挑「没说过 + 6 小时内 + notable」的事件，渲染成一段由头交给 `proactive.js` |
| `node-plugin/lib/world-life.js` | 读方之二：渲染成 `qq:world-life` 人设段（`WORLD_LIFE_ORDER=200`），她一开口就知道自己刚才在干嘛 |

两个读方互不知道对方，也都不写 feed。去重只在 bridge 侧有：`/var/lib/dsh-qq-bridge/world-life.json` 记住「哪几条已经说过」；node 侧是无状态的，每轮直接读 feed 的尾巴渲染人设段（它只需要「我刚才在干嘛」，不需要避免重复）。

## 线上 env

`/etc/dsh-qq-bridge/env`：

```
WORLD_LIFE_ENABLED=on
WORLD_LIFE_MAX_PER_DAY=2
WORLD_LIFE_WINDOW_HOURS=6
WORLD_LIFE_FILE=/opt/whale-craft/life-feed.jsonl
PROACTIVE_MAX_PER_DAY=2
PROACTIVE_MAX_ASKS_PER_DAY=3
PROACTIVE_MIN_GAP_MS=10800000
```

## 怎么验

```bash
# 1. 事件真的在写
tail -n 5 /opt/whale-craft/life-feed.jsonl
# 2. 写方自测（不碰真实世界，只追加一条 thought）
cd /opt/whale-craft && node life.cjs --selftest
# 3. 闸门有没有武装
journalctl -u dsh-qq-bridge -n 200 | grep "proactive gate armed"
# 4. 她说过哪件事（由头不落库原文，落在 tasks.proactive_cue）
sqlite3 /var/lib/dsh-qq-bridge/queue.db "select created_at, substr(proactive_cue,1,60) from tasks where COALESCE(proactive_cue,'') <> '' order by created_at desc limit 5;"
```

## 待办（已知未做）

- **没有轮转**：`life.cjs` 只 `appendFileSync`。`thought` 按 10 分钟一条算，一天 144 行、一年 5 万行——量不大但不会自己停，
  将来要么按月切文件，要么在读方只读尾巴 200 行（现在读方每次全量读，文件大了会慢）。
- **`explore` 触发太密**：按累计路程 300 格算，探索模式一小时能刷满；它不 notable，所以只影响文件体积。
- **`first` 的去重是进程内**：重启 bot 后同一件事会再记一次；因为它 notable，可能被当成新由头。短期无害（有 6 小时窗口与日额度），长期要落盘去重。
- **`home-built.json` / `home-site.json` 是运行态、不在部署包里**：换机器后她会以为房子还没盖，重盖一次（fill 幂等，方块不会变，只是重新种一遍花，实测 21:22 那次 7 朵花、坐标与原设计一致）。搬家时想省这一步就把这两个文件一起带上。
