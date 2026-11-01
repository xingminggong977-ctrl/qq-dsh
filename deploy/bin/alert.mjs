// 独立于 DSH 的告警出口：直接连 NapCat 的 OneBot WS，给主人发一条私聊文字。
// 之所以不复用 bridge / node-plugin，是因为「她被卡住」时，那些组件本身可能正是故障点。
//
// 用法: NAPCAT_TOKEN=xxx node dsh-qq-alert.mjs "消息内容"
// 环境变量: NAPCAT_URL（默认 ws://127.0.0.1:3001）、NAPCAT_TOKEN、ALERT_QQ

const url = process.env.NAPCAT_URL || 'ws://127.0.0.1:3001'
const token = process.env.NAPCAT_TOKEN || ''
const user = process.env.ALERT_QQ || '10001'
const text = process.argv[2] || '(空消息)'

// NapCat 不同版本认 access_token 的方式不同：URL 查询串与 Authorization 头同时给。
const target = token
  ? `${url}${url.includes('?') ? '&' : '?'}access_token=${encodeURIComponent(token)}`
  : url

const echo = `health-${Date.now()}`
// 两参数 undici 形式才带得上头；WHATWG 三参数 new WebSocket(url, [], { headers }) 会静默丢头。
const socket = token ? new WebSocket(target, { headers: { Authorization: `Bearer ${token}` } }) : new WebSocket(target)

let settled = false
function finish(code, why) {
  if (settled) return
  settled = true
  clearTimeout(timer)
  try {
    socket.close()
  } catch {}
  if (why) process.stderr.write(`${why}\n`)
  process.exit(code)
}

const timer = setTimeout(() => finish(0, 'alert: 10 秒内没拿到回包'), 10_000)

socket.addEventListener('open', () => {
  socket.send(
    JSON.stringify({
      action: 'send_private_msg',
      params: { user_id: Number(user), message: [{ type: 'text', data: { text } }] },
      echo,
    }),
  )
})

socket.addEventListener('error', (event) => {
  finish(1, `alert: 连接 NapCat 失败: ${event?.message ?? String(event)}`)
})

socket.addEventListener('message', (event) => {
  let reply
  try {
    reply = JSON.parse(String(event.data))
  } catch {
    return
  }
  // 事件帧（群消息、通知、心跳）没有 retcode，不能当回包处理。
  if (typeof reply.retcode !== 'number') return
  if (reply.echo !== undefined && reply.echo !== echo) return
  finish(reply.retcode === 0 ? 0 : 1, reply.retcode === 0 ? '' : `alert: retcode=${reply.retcode} ${reply.wording ?? ''}`)
})
