# 她的声音：音色档案（voice registry）

一份可复现的记录：现在用的是哪个音色、素材在哪、怎么重做、怎么微调。
所有数字都是当场实测值，不是估算。

---

## 1. 当前线上音色（2026-10-28 17:19 起生效）

| 项 | 值 |
| --- | --- |
| 音色 ID | `cosyvoice-v2-changjiu-faac8822123d4c5592403508c31ffa41` |
| 前缀 / 模型 | `changjiu` / `cosyvoice-v2` |
| 云端状态 | `status: OK`，`gmt_create 2026-10-28 17:18:47`，`gmt_modified 17:18:53` |
| 复刻耗时 | 3036 ms |
| 接入方式 | `/etc/dsh-qq-bridge/env` 里 `TTS_PROVIDER=dashscope`、`TTS_MODEL=cosyvoice-v2`、`TTS_VOICE=<上面那串>` |
| 合成实测 | 26 字 → 113,775 字节 / 7.11 秒 / 平均 -22.9 dB / 峰值 -6.3 dB / 合成耗时 4058 ms |
| 首条试听 | 已发到主人 QQ，`message_id 1905479648`（NapCat `retcode 0`） |

## 2. 素材（可复现的源头）

| 项 | 值 |
| --- | --- |
| 原始文件 | 用户提供的 `日常闲聊内容记录.m4a`，507,679 字节，30.92 秒，平均 -31.4 dB |
| 处理后 | 24 kHz 单声道 PCM s16le，`volume=9dB,alimiter=limit=0.95` → 1,483,854 字节，30.91 秒，平均 -25.3 dB / 峰值 -6.8 dB |
| 服务器归档 | `/var/lib/dsh-qq-bridge/voices/changjiu-20261028.wav`（属主 dshqq，644） |
| 归档 sha256 | `3ccc212e8d77262a8b7dbf0062e10271475b472a28f97da2ccc655406a7604ec` |
| 本地副本 | `qq-dsh\deploy\voice-changjiu.wav` |

处理命令（复现用）：

```bash
ffmpeg -y -i 日常闲聊内容记录.m4a -ac 1 -ar 24000 \
  -af "volume=9dB,alimiter=limit=0.95" -c:a pcm_s16le voice-changjiu.wav
```

## 3. 怎么重做一次复刻

```bash
# 1) 上传素材
scp -i %USERPROFILE%\.ssh\qq_bridge_ed25519 voice-changjiu.wav root@203.0.113.10:/var/lib/dsh-qq-bridge/voice-changjiu.wav

# 2) 复刻（必须用 /opt/asr-venv/bin/python：系统 python3 没有 dashscope）
bash /tmp/enroll-changjiu.sh /var/lib/dsh-qq-bridge/voice-changjiu.wav changjiu cosyvoice-v2
# → {"voiceId": "cosyvoice-v2-changjiu-<uuid>", ...}

# 3) 切线上 + 合成 + 发试听
bash /tmp/switch-voice.sh <voiceId> cosyvoice-v2
```

脚本都在 `qq-dsh\deploy\`：`enroll-changjiu.sh`、`switch-voice.sh`、`save-voice.sh`。

## 4. 微调旋钮（都不需要重新复刻）

| env 键 | 默认 | 范围 | 作用 |
| --- | --- | --- | --- |
| `TTS_SPEECH_RATE` | 1.0 | 0.5–2 | 语速倍率，<1 更慢更柔 |
| `TTS_PITCH_RATE` | 1.0 | 0.5–2 | 音高倍率，<1 更低沉 |
| `TTS_MODEL` | `cosyvoice-v2` | v1/v2/v3-flash/v3-plus/v3.5-flash/v3.5-plus | 换合成模型（音色 ID 与模型绑定，换模型要重新复刻） |
| `TTS_MAX_CHARS` | 60 | 1–500 | 超过这个字数就不发语音，改打字 |
| `TTS_DAILY_MAX` | 20 | 0–500 | 每天最多几条语音 |

改完 `systemctl restart dsh-qq-bridge` 生效。

**注意**：音色 ID 里带着模型名（`cosyvoice-v2-changjiu-…`），换 `TTS_MODEL` 必须用同模型的音色重新复刻，否则合成会报错。想用 `cosyvoice-v3.5-plus` 得拿同一段素材再复刻一次。

## 5. 已知的坑（都踩过）

1. 服务器 `python3` 是系统解释器，没有 `dashscope` → 一律 `/opt/asr-venv/bin/python`（dashscope 2.0.2）。
2. 官方音色名带版本后缀：`longxiaochun_v2` 可用，`longxiaochun` 配 `cosyvoice-v2` 会得到 `Engine return error code: 418`。
3. `TTS_DASHSCOPE_KEY` 为空时回落到 `ASR_DASHSCOPE_KEY`（`bridge/src/config.js:123`），所以只配一个 key 就够。
4. 语音回复只对**主人的私聊**生效，且文本超过 `TTS_MAX_CHARS` 时不发语音（`bridge/src/dispatch.js` 里判断）。

## 6. 当前线上音色（2026-10-28 17:31 起，已锁定为长期使用）

| 项 | 值 |
| --- | --- |
| 音色 ID | `cosyvoice-v3.5-plus-changjiu35-e1b766f1abe84d24a3fefdec27e22b2b` |
| 前缀 / 模型 | `changjiu35` / `cosyvoice-v3.5-plus` |
| 语速 / 音高 | `TTS_SPEECH_RATE=1.1` / `TTS_PITCH_RATE=1.0`（用户要求「快 1.1 倍」） |
| 风格指令 | `TTS_INSTRUCTION=用自然、随意的聊天语气说，像跟熟人讲话，不要念稿` |
| 复刻耗时 | 3422 ms（素材与 v2 同一个 wav） |
| 锁定时验证 | 32 字 → 109,178 字节 / 6.82 秒 / 回读与原文逐字一致；发送 `message_id 1472595289` |

素材身份已核对：用户 17:30 又发了一次同一个文件，sha256 `4246f27a73eda6514646297216a73abcce670919e56b9656450cc5c5f74b1fa6`，与首次那份**逐字节相同**，所以没有重新复刻。

回退到 v2 只需两条 env：`TTS_MODEL=cosyvoice-v2`、`TTS_VOICE=cosyvoice-v2-changjiu-faac8822123d4c5592403508c31ffa41`，再重启服务。

### 三版对照（同一句话，都已真跑合成 + whisper 回读）

| 配置 | 26 字那句 | 27 字那句 | 回读校验 |
| --- | --- | --- | --- |
| v2 / 语速 1.0 | 7.11 s | — | — |
| v2 / 语速 1.1 | 6.48 s | 16.12 s（多念了「不赶紧这样的……」） | 有尾巴漂移 |
| v3.5-plus / 语速 1.1 + 风格指令 | 5.02 s | 4.44 s | 逐字一致 |
| v3.5-plus / 语速 1.2 + 风格指令 | 6.03 s（另一句） | 5.54 s | 逐字一致 |

选择理由：v3.5-plus 时长更贴合文本、不拖尾，且支持风格指令压掉念稿感。

**用户确认（2026-10-28 17:33）**：「就这个了，我就要这个。」—— 定为长期音色，不再改。

核对样本（都真跑过 whisper 回读，作为「不念错」的证据）：

| 样本 | 文本 | 时长 | 回读结果 |
| --- | --- | --- | --- |
| `message_id 194863602` | 好了，就定下这个声音了。以后我一直这么跟你说话，你听着顺耳就行。 | 6.82 s | 逐字一致；与 17:30 那条**逐字节相同**（109,178 字节） |
| `message_id 1328950804` | 明天下午三点半我要去杭州东站，记得提醒我带身份证和充电宝，别又忘了。 | 7.71 s | 逐字一致（「三点半」读作 3 点半，数字/地名/并列/否定四类均无错） |

### 真正走到聊天里还差一个闸门

`bridge/src/dispatch.js:266` —— `if ([...prepareSpeech(text)].length > voiceMaxChars) return null`。
也就是说**只有 120 字以内的回复才会发语音**（`TTS_MAX_CHARS=120`，2026-10-28 17:34 由 60 放宽），每天最多 20 条（`TTS_DAILY_MAX=20`，`dispatch.js:272`）。

线上解析结果（用 bridge 自己的 `loadConfig` 打印，不是看 env 猜）：
`{"model":"cosyvoice-v3.5-plus","voice":"cosyvoice-v3.5-plus-changjiu35-…","speechRate":1.1,"pitchRate":1,"maxChars":120,"dailyMax":20,"instruction":"用自然、随意的聊天语气说，像跟熟人讲话，不要念稿"}`

### 部署坑（吃了两个小时）

`deploy/deploy-bridge.sh` 解的是服务器上的 `/tmp/bridge.tar.gz`，**不会自己从源码打包**。
第一次改完 `tts.js` / `config.js` 只跑了 `deploy-bridge.sh`，于是部署的还是旧 tar —— 服务器上 `grep TTS_INSTRUCTION` 命中 0，env 里那条指令被静默忽略。
正确姿势：先本地 `tar -czf deploy/bridge.tar.gz bridge`（顶层目录必须叫 `bridge`），scp 上去，再跑 `deploy-bridge.sh`。

## 7. 待办

- [ ] 用户听完反馈像不像；不像就掐掉闲聊空隙取 15~30 秒干净片段重录。
- [ ] 需要更高拟人度时，用同素材复刻 `cosyvoice-v3.5-plus` 版本。
