# 对照《大肥鱼系统：技术术语与概念文档 v2.0》看她这套记忆，能抄的只有三条

来源：主人转来的抖音图文（作者 hwhsh，v2.0 / 2026-10-26 / 阿里云 ECS + NapCat + DSH + DeepSeek），十五张截图，
内容是一份把自己这套长期对话体的记忆、动机、具身环境、社会交互写成术语表与公式的文档。
它自己第 1.1 节就把「机制（可计算、可验证）」与「隐喻（借名组织设计）」分开了，第 8 节又写了「不主张主观体验」——
这点很干净，值得照抄态度。

她的实现（`qq-dsh/node-plugin/lib/`：`memory.js` / `recall.js` / `remember.js` / `persona.js`）在 2026-11-01 之前的状态是：
加权条目 + 分档遗忘曲线 + 注入预算 + 夜班合并 + `recall` 关键词检索。文档里出现、而她这里一个都没有的：
惊讶度写入权重、去重、稀有词加权、检索多样性、反刍抑制、分区（region）、向量通道、图结构。

## 一、真正抄了的三条

判据只有两个：**纯 JS、不调模型**（不增加她每回合的往返次数），以及**不动她已经写下的记忆**（主人的红线是「不要把她搞崩溃或者忘记事情」）。

### 1. 近重复判定：Jaccard 0.60 且 包含度 0.78（§2.7）

文档的去重条件是「Jaccard 相似度 ≥ 0.60 **且** 包含度 ≥ 0.78 **且** 同 region 或共享标签」。
单看相似度会出事：`他养了一盆薄荷` 与 `他养了一盆薄荷，浇多了会烂根` 的 Jaccard 只有 0.6 上下，但后者就是前者加了细节，
按相似度会当成两条，按包含度会当成一条。这两条阈值一起用才既不错并、也不漏并。

落在 `qq-dsh/node-plugin/lib/memory.js`：

```js
similarityTokens(text)     // 拉丁整词 + 中文二元组（两个都是停用字就丢），无二元组退回单字
jaccardSimilarity(a, b)    // 交集 / 并集
containment(a, b)          // 交集 / 较小一侧
DUPLICATE_JACCARD = 0.6
DUPLICATE_CONTAINMENT = 0.78
isNearDuplicate(a, b)      // 两条阈值同时满足
```

### 2. 词法通道改用 idf（§2.5）

文档的检索是三路融合（词法 `rareTokens` + 语义余弦 + 结构 PageRank），融合式 `score = 0.65·cos + 0.35·lex`。
她这里没有向量库，语义那一路做不了；但「稀有词加权」这一半不需要模型，改一个函数就有：

`recall.js` 原来是「查到的词每命中一次 +1」，于是 `他`、`的`、`今天` 这种词把分数刷满。
现在先统计每个 token 出现在多少行（`docFreq`），再按 `log(1 + 总行数 / (1 + 含有该词的行数))` 加权，整句原样命中额外 `+2`。

### 3. 检索多样性（§2.5 卦象多样性的量化版）

文档用「已选同卦节点按 0.86 / 0.72 递减」来避免检索同质化。她的场景小得多，同质化的表现就是**同一句话进了两次提示词**——
一条在 `MEMORY.md`、一条在日记里，或者同一件事被写了两遍。量化成「同一句话只注一次」：

- `recall.js`：命中集里与已选条目 Jaccard ≥ `RECALL_SIMILAR_HIT` (0.8) 的直接跳过，让位给别的候选。
- `persona.js`：`#diverseItems(items)` 在装配时丢掉与已选条目 `isNearDuplicate` 的条目，日志 `memory:similar`。
- 两处都只影响「这一次显示什么」，**一个字都不改文件**；被丢的那条仍在 `MEMORY.md` 里，`recall` 照样翻得到。
- `w5` 与 `identity` / `rule` 钉住的条目永不因此被丢。

## 二、明确没抄的，及原因

| 文档里的东西 | 不抄的原因 |
| --- | --- |
| §2.3 有向加权图 + 512 维向量双通道 | 要 embedding 服务与向量库。桥里虽然有 dashscope key（ASR/TTS 在用），但每回合多一次网络调用，延迟与费用都得实测；现在 279 个用例的纯函数实现零成本 |
| 个人化 PageRank（图通道扩散激活） | 依赖上面那张图；35 条记忆中最大连通块就是「她自己的生活」 |
| §3 六十四卦 6 位状态编码 | 文档自己也说是「索引结构、不涉及占断」。她的条目量级 35 条，关键词索引足够；加了只是多一层映射 |
| §4 六维驱力 + 玻恩规则抽样 | 她已经有 world-life 与 proactive 闸门在决定「什么时候开口」，再插一套抽样会打架。要做也得先把现有闸门量清楚（见 `docs/latency-profile-2026-11-01.md` 的口径） |
| §5 具身模拟环境（双重空间、太阳几何、生态与经济） | 她的 whale-craft `life-feed.jsonl` 已经在做这件事，重复建设 |
| §6 群聊概率触发（`p = min(0.85, p0 + 0.12r)`） | 群里多发一句就是噪声；她的群聊参与是「被 @ 才答」，这是产品决定，不是缺陷 |
| §2.2 惊讶度写入权重 `w0 = w_base·(1+s)` | **可做但没做**：需要写入时对全部条目算一遍 max Jaccard（35 条 × 一天几次，成本可忽略）。风险是权重漂移，改的是**新写入**的条目，得先看几天写入分布再动；`w_base` 主人 4.0 / 其他 1.5 也不该直接照搬她的 1–5 档 |

## 三、证据

- `qq-dsh/node-plugin/lib/memory.js` 新增 `similarityTokens` / `jaccardSimilarity` / `containment` / `isNearDuplicate` 与两个阈值常量。
- `qq-dsh/node-plugin/lib/remember.js` 新增 `findNearDuplicate`，`append` 在精确重复之后多一档「换个说法」，返回 `{ duplicated: true, nearDuplicate: true, line }`。
- `qq-dsh/node-plugin/lib/recall.js` 打分改 idf 加权 + 整句 `+2`，命中集按 `RECALL_SIMILAR_HIT = 0.8` 去重。
- `qq-dsh/node-plugin/lib/persona.js` 新增 `#diverseItems`，与 `#countInjections` 相邻调用。
- 用例：`test/remember.test.js` +3、`test/recall.test.js` +1（含 recall 7b）、`test/persona.test.js` +1（persona 6）；全量 **279 pass / 0 fail**。

## 四、如果还要往前一步（按性价比排序）

1. ~~**分区预算**（§2.1 的 region）~~ **已做（2026-11-01 晚）**：`LIMITS.opsMemoryBytes` / `LIMITS.noteMemoryBytes` 各 3 KiB，`persona.js` 新增 `#capKinds(items)`，在 `#diverseItems` 之后、`#countInjections` 之前跑。钉住的条目不受池子限制，日志 `memory:pool`。用例 `persona 7`（40 条 ops 只放进 24 条、事件与钉住条目照旧、文件不动），全量 **280 pass / 0 fail**。
2. ~~**惊讶度写入权重**（§2.2）~~ **已做，但收窄（2026-11-01 晚）**：`remember.js` 新增 `maxSimilarity` 与 `SURPRISE_NOVEL = 0.8`，`s ≥ 0.8` 且她给 3 分时抬到 4 分——**只抬一档、绝不抬到 5**。论文原式 `w0 = w_base·(1+s)`（主人 4.0）会只凭「这条很新」就把一次性细节抬到接近钉住，与「不要把她搞清楚之外的东西也钉住」冲突；所以这里只借它「新的事该多活一阵」这一半意思，钉住权永远留给主人和她自己。用例 `remember — a brand-new fact gets one notch of surprise, never a pin`，全量 **281 pass / 0 fail**。
3. **反刍抑制**（§2.6）：同一批条目在短时间内被反复注入时不加 `reviews`——这一点她本来就对（注入不计复习），只差一个「短时间内反复 `recall` 到同一行就降权」的小账本。
