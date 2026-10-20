/**
 * End-to-end through a connection: the method table, the cursor semantics,
 * the activity feed, the queue, the archive — exactly as a GUI drives them.
 */

import { describe, expect, it } from 'vitest'
import { harness, scriptedEngine } from './helpers/harness.ts'
import { eventOf } from '../src/core/records.ts'
import type { SessionRecord } from '../src/core/records.ts'

async function makeReady() {
  const h = await harness({
    engine: scriptedEngine([{ text: 'Answer one.' }, { text: 'Answer two.' }]),
  })
  const created = (await h.call('session.create', {})) as { sessionId: string }
  return { h, sessionId: created.sessionId }
}

describe('the method table', () => {
  it('answers ping, host.info, session.list and the catalogs', async () => {
    const { h } = await makeReady()
    expect(await h.call('ping')).toEqual({ pong: true })
    expect(await h.call('host.info')).toMatchObject({ protocolVersion: 1, hostName: 'test-host' })
    const list = (await h.call('session.list')) as { items: unknown[] }
    expect(list.items).toHaveLength(1)
    const models = (await h.call('model.catalog')) as { providers: unknown[]; default: unknown }
    expect(models.providers).toHaveLength(1)
    expect(models.default).toMatchObject({ provider: 'deepseek-official', model: 'deepseek-chat' })
    const permissions = (await h.call('permissions.catalog')) as { defaultPreset: string }
    expect(permissions.defaultPreset).toBe('workspace-write')
  })

  it('answers push compatibly and uploads with NOT_IMPLEMENTED', async () => {
    const { h } = await makeReady()
    expect(await h.call('push.register', { token: 'deadbeef', environment: 'sandbox' })).toEqual({
      registered: false,
    })
    expect(await h.call('push.presence', { foreground: true })).toEqual({ accepted: true })
    expect(await h.call('push.unregister')).toEqual({ unregistered: true })
    await expect(h.call('upload.begin', { sessionId: 's', kind: 'image', name: 'a', mediaType: 'image/png', byteSize: 1 })).rejects.toThrow(
      /NOT_IMPLEMENTED/,
    )
  })

  it('refuses bad payloads with MALFORMED_FRAME, per method', async () => {
    const { h, sessionId } = await makeReady()
    await expect(h.call('session.messages', { sessionId })).resolves.toBeTruthy()
    await expect(h.call('session.messages', {})).rejects.toThrow(/sessionId.*non-empty/)
    await expect(h.call('session.messages', { sessionId, afterSeq: -1 })).rejects.toThrow(/afterSeq/)
    await expect(h.call('session.activity', { sessionId, beforeSeq: 5 })).rejects.toThrow(/"turn" is required/)
    await expect(h.call('approval.answer', { requestId: 'x', outcome: 'always' })).rejects.toThrow(
      /must be "allowed-once" or "rejected"/,
    )
    await expect(h.call('push.register', Object.fromEntries([['token', 'ab'], ['platform', 'Android']]))).rejects.toThrow(/"ios" or "android"/)
    await expect(h.call('session.prompt', { sessionId, mode: 'interrupt' })).rejects.toThrow(/"queue" or "steer"/)
    await expect(h.call('no.such.method', {})).rejects.toThrow(/NOT_IMPLEMENTED/)
  })

  it('renames and reflects the title in stats, missing fields stay missing', async () => {
    const { h, sessionId } = await makeReady()
    expect(await h.call('session.rename', { sessionId, title: 'My session' })).toEqual({ renamed: true })
    const stats = (await h.call('session.stats', { sessionId })) as { stats: Record<string, unknown> }
    expect(stats.stats['title']).toBe('My session')
    // A blank session has run no turn: tokenUsage is absent, not zero.
    expect('tokenUsage' in stats.stats).toBe(false)
    // turns/steps are counted from the log.
    expect(stats.stats['stats']).toMatchObject({ turns: 0, steps: 0 })
  })

  it('sets a model from the catalog and refuses one outside it', async () => {
    const { h, sessionId } = await makeReady()
    const selected = (await h.call('session.model.set', {
      sessionId,
      provider: 'deepseek-official',
      model: 'deepseek-reasoner',
    })) as { selected: unknown }
    expect(selected.selected).toMatchObject({ provider: 'deepseek-official', model: 'deepseek-reasoner' })
    await expect(
      h.call('session.model.set', { sessionId, provider: 'deepseek-official', model: 'not-a-model' }),
    ).rejects.toThrow(/MODEL_UNAVAILABLE/)
  })

  it('sets a permission preset and refuses an unknown one like the desktop', async () => {
    const { h, sessionId } = await makeReady()
    await h.call('session.permission.set', { sessionId, preset: 'read-only' })
    const stats = (await h.call('session.stats', { sessionId })) as { stats: Record<string, unknown> }
    expect(stats.stats['permissionPreset']).toBe('read-only')
    await expect(h.call('session.permission.set', { sessionId, preset: 'not-a-preset' })).rejects.toThrow(
      /unknown preset "not-a-preset"/,
    )
  })

  it('reports the kernel extension surfaces', async () => {
    const { h } = await makeReady()
    expect(await h.call('kernel.status')).toMatchObject({ engine: 'openai-compat', protocolVersion: 1 })
    expect(await h.call('kernel.apiKey.set', { provider: 'deepseek-official', key: 'sk-test' })).toEqual({ set: true })
    expect(await h.call('kernel.apiKey.status')).toEqual({
      providers: [{ id: 'deepseek-official', name: 'DeepSeek', hasKey: true }],
    })
    await expect(h.call('kernel.apiKey.set', { provider: 'nope', key: 'x' })).rejects.toThrow(/no provider/)
    // The key never leaves the kv store through any read surface.
    const config = (await h.call('kernel.config.get')) as { config: Record<string, unknown> }
    expect(JSON.stringify(config)).not.toContain('sk-test')
  })
})

describe('session.messages cursor semantics', () => {
  it('a fresh read returns the summary page; the ledger answers the cursor-less follow-up', async () => {
    const { h, sessionId } = await makeReady()
    await h.call('session.prompt', { sessionId, text: 'first' })
    await h.waitTurnDone(sessionId)

    // Cursor-less read #1: the ledger has nothing, so the full summary tail.
    const first = (await h.call('session.messages', { sessionId })) as {
      records: SessionRecord[]
      asOfSeq: number
      hasMore: boolean
    }
    const types = first.records.map((record) => record.event.type)
    expect(types).toEqual(['turn/start', 'step/start', 'user/message', 'assistant/message', 'turn/end'])
    expect(first.hasMore).toBe(false)

    // Cursor-less read #2: the ledger marked everything delivered — empty.
    const second = (await h.call('session.messages', { sessionId })) as { records: unknown[] }
    expect(second.records).toEqual([])

    // afterSeq: null says "I hold nothing" — full tail again, ledger ignored.
    const third = (await h.call('session.messages', { sessionId, afterSeq: null })) as {
      records: SessionRecord[]
    }
    expect(third.records).toHaveLength(5)

    // A numeric afterSeq returns only newer records.
    const secondRecord = first.records[1]
    if (secondRecord === undefined) throw new Error('summary page lost its records')
    const cutoff = secondRecord.event.seq
    await h.call('session.prompt', { sessionId, text: 'second' })
    await h.waitTurnDone(sessionId)
    const fourth = (await h.call('session.messages', { sessionId, afterSeq: cutoff })) as {
      records: SessionRecord[]
    }
    for (const record of fourth.records) {
      expect(record.event.seq).toBeGreaterThan(cutoff)
    }
    // The second turn's summary is complete on its own.
    expect(fourth.records.map((record) => record.event.type)).toContain('assistant/message')
  })

  it('beforeSeq pages backwards and is not filtered by afterSeq', async () => {
    const { h, sessionId } = await makeReady()
    await h.call('session.prompt', { sessionId, text: 'only' })
    await h.waitTurnDone(sessionId)
    const full = (await h.call('session.messages', { sessionId, afterSeq: null })) as {
      records: SessionRecord[]
      asOfSeq: number
    }
    expect(full.records.length).toBeGreaterThanOrEqual(5)

    const page = (await h.call('session.messages', {
      sessionId,
      beforeSeq: full.asOfSeq,
      maxMessages: 2,
    })) as { records: SessionRecord[]; hasMore: boolean }
    // The window is the last two raw records before the cut; the summary
    // filter keeps only what the conversation screen draws, so fewer
    // records can survive than the window held.
    expect(page.records.length).toBeLessThanOrEqual(2)
    expect(page.records.length).toBeGreaterThanOrEqual(1)
    for (const record of page.records) {
      expect(record.event.seq).toBeLessThan(full.asOfSeq)
    }
    expect(page.hasMore).toBe(true)
  })

  it('an unknown session is an empty answer, not an error', async () => {
    const { h } = await makeReady()
    const result = (await h.call('session.messages', { sessionId: 'session-none' })) as {
      asOfSeq: unknown
      records: unknown[]
    }
    expect(result.asOfSeq).toBeNull()
    expect(result.records).toEqual([])
  })
})

describe('session.activity', () => {
  it('streams the running turn as one-line rows and clears when it ends', async () => {
    // The first engine step waits on a gate, so the turn is genuinely
    // running while the test polls the feed.
    let release: () => void = () => {}
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    let release2: () => void = () => {}
    const gate2 = new Promise<void>((resolve) => {
      release2 = resolve
    })
    const h = await harness({
      engine: scriptedEngine([
        async () => {
          await gate
          return {
            deltas: [{ reasoning: 'Thinking about it carefully' }],
            toolCalls: [
              { callId: 'c9', name: 'list_dir', arguments: '{"path":".","description":"check the workspace"}' },
            ],
          }
        },
        async () => {
          await gate2
          return { text: 'Empty.' }
        },
      ]),
    })
    const { sessionId } = (await h.call('session.create', {})) as { sessionId: string }
    h.connection.send(
      JSON.stringify({ v: 1, id: 'p1', type: 'session.prompt', payload: { sessionId, text: 'look around' } }),
    )
    await h.waitFor(
      () => h.frames.some((frame) => frame.type === 'ok' && JSON.stringify(frame).includes('"requestId"')),
      'prompt accepted',
    )

    // While the first step is gated, the turn is running but has produced
    // no rows yet: the feed is empty and that is the honest answer.
    const gated = (await h.call('session.activity', { sessionId })) as {
      turn: number | null
      entries: unknown[]
    }
    expect(gated.turn).toBe(1)
    expect(gated.entries).toEqual([])

    // Release the first step; its attempt and tool rows land, and the turn
    // keeps running on the gated second step.
    release()
    let sawToolRow = false
    for (let attempt = 0; attempt < 100 && !sawToolRow; attempt += 1) {
      const activity = (await h.call('session.activity', { sessionId })) as {
        turn: number | null
        entries: { id: string; kind: string; title: string; text: string }[]
      }
      expect(activity.turn).toBe(1)
      const kinds = activity.entries.map((entry) => entry.kind)
      if (kinds.includes('thinking') && kinds.includes('tool')) {
        sawToolRow = true
        const toolRow = activity.entries.find((entry) => entry.kind === 'tool')
        if (toolRow !== undefined) {
          expect(toolRow.title).toBe('list_dir')
          expect(toolRow.text).toContain('check the workspace')
          expect(toolRow.id).toMatch(/^seq-\d+$/)
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 5))
    }
    expect(sawToolRow).toBe(true)

    // Release the second step; the turn completes and the feed clears.
    release2()
    await h.waitTurnDone(sessionId)
    const ended = (await h.call('session.activity', { sessionId })) as { turn: unknown; entries: unknown[] }
    expect(ended.turn).toBeNull()
    expect(ended.entries).toEqual([])
  })
})

describe('prompt queueing and archive', () => {
  it('queues a prompt that arrives mid-turn and runs it after', async () => {
    const h = await harness({
      engine: scriptedEngine([{ text: 'first answer' }, { text: 'second answer' }]),
    })
    const { sessionId } = (await h.call('session.create', {})) as { sessionId: string }
    h.connection.send(JSON.stringify({ v: 1, id: 'p1', type: 'session.prompt', payload: { sessionId, text: 'one' } }))
    await h.waitFor(() => h.frames.some((frame) => JSON.stringify(frame).includes('"requestId"')), 'accepted')
    // A second prompt while the first turn runs: queued.
    const second = (await h.call('session.prompt', { sessionId, text: 'two', mode: 'queue' })) as {
      accepted: boolean
      requestId: string
    }
    expect(second.accepted).toBe(true)
    await h.waitTurnDone(sessionId)

    const messages = (await h.call('session.messages', { sessionId, afterSeq: null })) as {
      records: SessionRecord[]
    }
    const prompts = messages.records
      .filter((record) => record.event.type === 'user/message')
      .map((record) => (record.event.data as { content: { text: string }[] }).content[0]?.text)
    expect(prompts).toEqual(['one', 'two'])
    const answers = messages.records.filter((record) => record.event.type === 'assistant/message')
    expect(answers).toHaveLength(2)
  })

  it('refuses to archive a running session without stopActivity, and stops with it', { timeout: 20_000 }, async () => {
    const h = await harness({
      engine: scriptedEngine([
        { toolCalls: [{ callId: 'h', name: 'ask_user_question', arguments: '{"questions":[{"question":"waiting"}]}' }] },
      ]),
    })
    const { sessionId } = (await h.call('session.create', {})) as { sessionId: string }
    h.connection.send(JSON.stringify({ v: 1, id: 'p1', type: 'session.prompt', payload: { sessionId, text: 'hang' } }))
    await h.waitFor(() => h.frames.some((frame) => JSON.stringify(frame).includes('"requestId"')), 'accepted')
    await h.waitFor(() => JSON.stringify(h.frames).includes('question.request'), 'question card')

    await expect(h.call('session.archive', { sessionId })).rejects.toThrow(/running turn/)
    const archived = (await h.call('session.archive', { sessionId, stopActivity: true })) as {
      archived: boolean
    }
    expect(archived.archived).toBe(true)
    // The archived session leaves every list, and the stopped turn's records
    // stay readable through the summary page.
    await h.waitFor(async () => {
      const list = (await h.call('session.list')) as { items: { sessionId: string }[] }
      return !list.items.some((item) => item.sessionId === sessionId)
    }, 'archived session leaves the list')
    const list = (await h.call('session.list')) as { items: unknown[] }
    expect(list.items).toEqual([])
  })
})

describe('turn errors over the wire', () => {
  it('a missing API key ends the turn with MISSING_CREDENTIAL, through the real engine', async () => {
    // The real OpenAI-compatible engine with no key configured.
    const h = await harness()
    const { sessionId } = (await h.call('session.create', {})) as { sessionId: string }
    h.connection.send(JSON.stringify({ v: 1, id: 'p1', type: 'session.prompt', payload: { sessionId, text: 'hi' } }))
    await h.waitFor(() => h.frames.some((frame) => JSON.stringify(frame).includes('"requestId"')), 'accepted')
    await h.waitTurnDone(sessionId)
    const messages = (await h.call('session.messages', { sessionId, afterSeq: null })) as {
      records: SessionRecord[]
    }
    const end = messages.records[messages.records.length - 1]
    if (end === undefined) throw new Error('the turn wrote no records')
    expect(end.event.type).toBe('turn/end')
    expect(eventOf(end)?.data).toMatchObject({
      reason: { kind: 'error', error: { code: 'MISSING_CREDENTIAL' } },
    })
  })
})
