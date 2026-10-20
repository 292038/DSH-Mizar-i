/**
 * The session store: the log, the cursors, the crash rules.
 */

import { describe, expect, it } from 'vitest'
import { SessionStore } from '../src/core/session-store.ts'
import { NodeHost } from './helpers/node-host.ts'

async function makeStore(): Promise<{ store: SessionStore; host: NodeHost; root: string }> {
  const os = await import('node:os')
  const fs = await import('node:fs')
  const path = await import('node:path')
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mizar-store-'))
  const host = new NodeHost(root)
  const store = new SessionStore(host, `${host.home}/workspace`)
  await store.load()
  return { store, host, root }
}

describe('SessionStore', () => {
  it('creates sessions and lists them newest-activity-first', async () => {
    const { store } = await makeStore()
    const first = await store.create({})
    await store.append(first.sessionId, 'turn/start', { turn: 1 })
    const second = await store.create({})
    await store.append(second.sessionId, 'turn/start', { turn: 1 })

    const rows = store.list()
    expect(rows.map((row) => row.sessionId)).toEqual([second.sessionId, first.sessionId])
    expect(rows[0]).toMatchObject({ running: false, blank: false, agentAvailable: true })
  })

  it('persists records to the log and reloads them', async () => {
    const { store, host, root } = await makeStore()
    const session = await store.create({})
    await store.append(session.sessionId, 'turn/start', { turn: 1 })
    await store.append(session.sessionId, 'turn/end', { turn: 1, reason: { kind: 'completed' } })

    const reloaded = new SessionStore(host, `${host.home}/workspace`)
    await reloaded.load()
    const records = reloaded.records(session.sessionId)
    expect(records.map((record) => record.event.type)).toEqual(['turn/start', 'turn/end'])
    expect(records.map((record) => record.event.seq)).toEqual([1, 2])
    expect(reloaded.rowOf(session.sessionId)?.running).toBe(false)
    void root
  })

  it('skips a torn tail line instead of failing the session', async () => {
    const { store, host } = await makeStore()
    const session = await store.create({})
    await store.append(session.sessionId, 'turn/start', { turn: 1 })
    // Simulate a crash mid-append.
    const existing = await new Promise<string | null>((resolve) =>
      host.fs.readText(`sessions/${session.sessionId}/log.jsonl`, { ok: resolve, fail: () => resolve(null) }),
    )
    await new Promise<void>((resolve) =>
      host.fs.writeText(`sessions/${session.sessionId}/log.jsonl`, (existing ?? '') + '{"type":"event","event":{"ty', {
        ok: () => resolve(),
        fail: () => resolve(),
      }),
    )

    const reloaded = new SessionStore(host, `${host.home}/workspace`)
    await reloaded.load()
    // The torn line is skipped, and the unterminated turn is closed by the
    // boot rule as a restart casualty.
    expect(reloaded.records(session.sessionId).map((record) => record.event.type)).toEqual([
      'turn/start',
      'turn/end',
    ])
  })

  it('closes a turn left running by a restart, as stopped', async () => {
    const { store, host } = await makeStore()
    const session = await store.create({})
    const turn = store.allocateTurn(session.sessionId)
    await store.beginTurn(session.sessionId, turn)
    await store.append(session.sessionId, 'turn/start', { turn })
    // No turn/end: a crash happened here.

    const reloaded = new SessionStore(host, `${host.home}/workspace`)
    await reloaded.load()
    const records = reloaded.records(session.sessionId)
    const last = records[records.length - 1]
    if (last === undefined) throw new Error('the restart wrote no closing record')
    expect(last.event.type).toBe('turn/end')
    expect(last.event.data).toMatchObject({ turn, reason: { kind: 'stopped' } })
    expect(reloaded.rowOf(session.sessionId)?.running).toBe(false)
  })

  it('archives non-destructively and hides the row from list', async () => {
    const { store } = await makeStore()
    const session = await store.create({})
    await store.append(session.sessionId, 'turn/start', { turn: 1 })
    await store.archive(session.sessionId)
    expect(store.list()).toEqual([])
    expect(store.get(session.sessionId)?.archived).toBe(true)
    // The log is still there.
    expect(store.records(session.sessionId).length).toBe(1)
  })

  it('refuses unsafe session ids', async () => {
    const { store } = await makeStore()
    await expect(store.create({ sessionId: '../escape' })).rejects.toMatchObject({ code: 'MALFORMED_FRAME' })
  })
})
