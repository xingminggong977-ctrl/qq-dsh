import { DatabaseSync } from 'node:sqlite'
const db = new DatabaseSync('/var/lib/dsh-qq-bridge/queue.db')
const row = db.prepare("select count(*) c from tasks where status not in ('done','failed')").get()
const rows = db.prepare("select task_id, status, datetime(received_at/1000,'unixepoch','localtime') t from tasks where status not in ('done','failed')").all()
console.log(row.c)
for (const r of rows) console.log('  ', r.t, r.status, r.task_id)
