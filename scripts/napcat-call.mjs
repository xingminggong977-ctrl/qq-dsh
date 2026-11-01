// 直接给 NapCat 发一条 OneBot 动作（走它自己的 WS 口），用来调扩展接口。
// 用法: NAPCAT_TOKEN=xxx node napcat-call.mjs <action> <params.json>
const [action, cfgPath] = process.argv.slice(2);
if (!action || !cfgPath) {
  console.error('用法: NAPCAT_TOKEN=... node napcat-call.mjs <action> <params.json>');
  process.exit(2);
}

const token = process.env.NAPCAT_TOKEN;
const url = process.env.NAPCAT_URL ?? 'ws://127.0.0.1:3001';
const params = JSON.parse((await import('node:fs')).readFileSync(cfgPath, 'utf8'));

const ws = new WebSocket(url, token ? { headers: { Authorization: `Bearer ${token}` } } : undefined);
const echo = `dsh-${Date.now()}`;

const done = (code, text) => {
  console.log(text);
  try { ws.close(); } catch {}
  process.exit(code);
};

const timer = setTimeout(() => done(1, 'TIMEOUT: 20s 内没等到回包'), 20000);

ws.addEventListener('open', () => {
  ws.send(JSON.stringify({ action, params, echo }));
});

ws.addEventListener('message', (event) => {
  let msg;
  try { msg = JSON.parse(String(event.data)); } catch { return; }
  if (msg.echo !== echo) return; // 别的推送（心跳、事件）不理
  clearTimeout(timer);
  done(msg.status === 'ok' || msg.retcode === 0 ? 0 : 1, JSON.stringify(msg, null, 2));
});

ws.addEventListener('error', (event) => {
  clearTimeout(timer);
  done(1, `WS 出错: ${event.message ?? event.error?.message ?? 'unknown'}`);
});
