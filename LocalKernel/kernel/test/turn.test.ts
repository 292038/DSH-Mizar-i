/**
 * The turn runner: one prompt, one true log story.
 */

import { describe, expect, it } from 'vitest'
import type { EngineAdapter } from '../src/engine/types.ts'
import { TurnRunner } from '../src/core/turn-runner.ts'
import { SessionStore } from '../src/core/session-store.ts'
import { InteractionsBroker } from '../src/core/interactions.ts'
import { eventOf } from '../src/core/records.ts'
import { NodeHost } from './helpers/node-host.ts'
import { scriptedEngine } from './helpers/harness.ts'

interface Fixture {
  runner: TurnRunner
  store: SessionStore
  broker: InteractionsBroker
  events: { event: string; data: unknown }[]
  sessionId: string
  host: NodeHost
}

async function makeFixture(engine: EngineAdapter): Promise<Fixture> {
  const os = await import('node:os')
  const fs = await import('node:fs')
  const path = await import('node:path')
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mizar-turn-'))
  const host = new NodeHost(root)
  const store = new SessionStore(host, `${host.home}/workspace`)
  await store.load()
  const events: { event: string; data: unknown }[] = []
  const broker = new InteractionsBroker((event, data) => events.push({ event, data }))
  const runner = new TurnRunner({ host, store, engine, broker, config: () => DEFAULT_CONFIG })
  const session = await store.create({})
  return { runner, store, broker, events, sessionId: session.sessionId, host }
}

import { DEFAULT_CONFIG } from '../src/core/config.ts'

function recordTypes(fixture: Fixture): string[] {
  return fixture.store.records(fixture.sessionId).map((record) => record.event.type)
}

describe('TurnRunner', () => {
  it('writes the full record story for a plain prompt-and-answer turn', async () => {
    const fixture = await makeFixture(
      scriptedEngine([
        {
          deltas: [{ text: 'Hello' }, { text: ',' }, { text: ' world' }],
          text: 'Hello, world',
        },
      ]),
    )
    await fixture.runner.run({
      sessionId: fixture.sessionId,
      text: 'hi',
      requestId: 'r1',
      signal: { aborted: false, onAbort: () => {} },
    })

    expect(recordTypes(fixture)).toEqual([
      'turn/start',
      'step/start',
      'user/message',
      'assistant/attempt',
      'assistant/message',
      'turn/end',
    ])
    const records = fixture.store.records(fixture.sessionId)
    const user = eventOf(records[2])
    expect(user?.data).toMatchObject({
      role: 'user',
      source: { kind: 'user', rpcId: 'r1' },
      content: [{ type: 'text', text: 'hi' }],
    })
    const attempt = eventOf(records[3])
    expect(attempt?.data).toMatchObject({
      turn: 1,
      step: 1,
      attempt: 1,
      stream: [{ type: 'text-chunks', texts: ['Hello', ',', ' world'] }],
    })
    const message = eventOf(records[4])
    expect(message?.data).toMatchObject({
      turn: 1,
      step: 1,
      message: { role: 'assistant', content: [{ type: 'text', text: 'Hello, world' }] },
    })
    expect(eventOf(records[5])?.data).toMatchObject({ turn: 1, reason: { kind: 'completed' } })
    expect(fixture.store.rowOf(fixture.sessionId)?.running).toBe(false)
  })

  it('runs tools in a second step and finishes completed', async () => {
    const fixture = await makeFixture(
      scriptedEngine([
        { toolCalls: [{ callId: 'c1', name: 'list_dir', arguments: '{"path":"."}' }] },
        { text: 'The workspace is empty.' },
      ]),
    )
    await fixture.runner.run({
      sessionId: fixture.sessionId,
      text: 'what is in the workspace?',
      requestId: 'r2',
      signal: { aborted: false, onAbort: () => {} },
    })

    const types = recordTypes(fixture)
    expect(types).toEqual([
      'turn/start',
      'step/start',
      'user/message',
      'tool/call',
      'tool/result',
      'step/start',
      'assistant/message',
      'turn/end',
    ])
    const records = fixture.store.records(fixture.sessionId)
    const call = eventOf(records[3])
    expect(call?.data).toMatchObject({ turn: 1, step: 1, callId: 'c1', name: 'list_dir' })
    const result = eventOf(records[4])
    expect(result?.data).toMatchObject({ callId: 'c1', name: 'list_dir' })
    expect((result?.data as { output?: string }).output).toContain('(empty directory)')
    expect(eventOf(records[types.length - 1])?.data).toMatchObject({ reason: { kind: 'completed' } })
  })

  it('raises an approval for a write under read-only, and the allowed-once covers one call', async () => {
    const fixture = await makeFixture(
      scriptedEngine([
        { toolCalls: [{ callId: 'w1', name: 'write_file', arguments: '{"path":"notes.md","content":"hello"}' }] },
        { text: 'Done.' },
      ]),
    )
    await fixture.store.setPermission(fixture.sessionId, 'read-only')

    // Answer the approval from "the operator's side" as soon as it appears.
    const answering = (async () => {
      await new Promise((resolve) => setTimeout(resolve, 20))
      const pending = fixture.broker.listApprovals()
      expect(pending).toHaveLength(1)
      const approval = pending[0]
      if (approval === undefined) throw new Error('no approval card appeared')
      expect(approval).toMatchObject({ toolName: 'write_file', sessionId: fixture.sessionId })
      fixture.broker.answerApproval(approval.requestId, 'allowed-once')
    })()

    await fixture.runner.run({
      sessionId: fixture.sessionId,
      text: 'write a note',
      requestId: 'r3',
      signal: { aborted: false, onAbort: () => {} },
    })
    await answering

    // The events the client would have seen.
    expect(fixture.events.map((event) => event.event)).toEqual([
      'approval.request',
      'interactions.changed',
      'approval.resolved',
      'interactions.changed',
    ])

    const types = recordTypes(fixture)
    const callIndex = types.indexOf('tool/call')
    const resultIndex = types.indexOf('tool/result')
    expect(resultIndex).toBe(callIndex + 1)
    const result = eventOf(fixture.store.records(fixture.sessionId)[resultIndex])
    expect((result?.data as { output?: string }).output).toContain('wrote')
    // The file landed in the session workspace.
    const written = await new Promise<string | null>((resolve) =>
      fixture.host.fs.readText(`workspace/${fixture.sessionId}/notes.md`, { ok: resolve, fail: () => resolve(null) }),
    )
    expect(written).toBe('hello')
  })

  it('records a denial as the tool result when the operator rejects', async () => {
    const fixture = await makeFixture(
      scriptedEngine([
        { toolCalls: [{ callId: 'w2', name: 'write_file', arguments: '{"path":"x.md","content":"y"}' }] },
        { text: 'Understood, I will not write.' },
      ]),
    )
    await fixture.store.setPermission(fixture.sessionId, 'read-only')
    const answering = (async () => {
      await new Promise((resolve) => setTimeout(resolve, 20))
      const pending = fixture.broker.listApprovals()
      const card = pending[0]
      if (card === undefined) throw new Error('no approval card appeared')
      fixture.broker.answerApproval(card.requestId, 'rejected')
    })()
    await fixture.runner.run({
      sessionId: fixture.sessionId,
      text: 'write it anyway',
      requestId: 'r4',
      signal: { aborted: false, onAbort: () => {} },
    })
    await answering

    const records = fixture.store.records(fixture.sessionId)
    const resultIndex = recordTypes(fixture).indexOf('tool/result')
    const result = eventOf(records[resultIndex])
    expect(result?.data).toMatchObject({
      error: { code: 'PERMISSION_DENIED' },
    })
    // Nothing was written.
    const written = await new Promise<string | null>((resolve) =>
      fixture.host.fs.readText(`workspace/${fixture.sessionId}/x.md`, { ok: resolve, fail: () => resolve(null) }),
    )
    expect(written).toBeNull()
  })

  it('routes ask_user_question through the broker and returns the answers', async () => {
    const fixture = await makeFixture(
      scriptedEngine([
        {
          toolCalls: [
            {
              callId: 'q1',
              name: 'ask_user_question',
              arguments:
                '{"questions":[{"question":"Which flavor?","options":[{"label":"Vanilla"},{"label":"Chocolate"}]}]}',
            },
          ],
        },
        { text: 'Vanilla it is.' },
      ]),
    )
    const answering = (async () => {
      await new Promise((resolve) => setTimeout(resolve, 20))
      const batches = fixture.broker.listQuestions()
      expect(batches).toHaveLength(1)
      const batch = batches[0]
      if (batch === undefined) throw new Error('no question batch appeared')
      expect(batch.questions[0]).toMatchObject({ id: 'q1', multiSelect: false })
      fixture.broker.answerQuestion(batch.callId, [{ id: 'q1', selected: ['Vanilla'] }])
    })()
    await fixture.runner.run({
      sessionId: fixture.sessionId,
      text: 'ask me something',
      requestId: 'r5',
      signal: { aborted: false, onAbort: () => {} },
    })
    await answering

    const records = fixture.store.records(fixture.sessionId)
    const resultIndex = recordTypes(fixture).indexOf('tool/result')
    const result = eventOf(records[resultIndex])
    expect((result?.data as { output?: string }).output).toContain('Vanilla')
    expect(fixture.events.some((event) => event.event === 'question.request')).toBe(true)
    expect(fixture.events.some((event) => event.event === 'question.resolved')).toBe(true)
  })

  it('ends an engine error as an error turn with the engine code', async () => {
    const fixture = await makeFixture(
      scriptedEngine([{ finishReason: 'error', errorCode: 'MISSING_CREDENTIAL', errorMessage: 'no API key' }]),
    )
    await fixture.runner.run({
      sessionId: fixture.sessionId,
      text: 'hi',
      requestId: 'r6',
      signal: { aborted: false, onAbort: () => {} },
    })
    const records = fixture.store.records(fixture.sessionId)
    const end = eventOf(records[records.length - 1])
    expect(end?.data).toMatchObject({
      reason: { kind: 'error', error: { code: 'MISSING_CREDENTIAL', message: 'no API key' } },
    })
  })

  it('ends a cancelled turn as stopped', async () => {
    const fixture = await makeFixture(
      scriptedEngine([
        // A tool that hangs until cancelled: the ask_user tool with no answerer,
        // and an arguments string whose JSON carries a nested double-quote.
        {
          toolCalls: [
            { callId: 'h1', name: 'ask_user_question', arguments: '{"questions":[{"question":"waiting"}]}' },
          ],
        },
      ]),
    )
    const running = fixture.runner.run({
      sessionId: fixture.sessionId,
      text: 'hang',
      requestId: 'r7',
      signal: { aborted: false, onAbort: () => {} },
    })
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(fixture.runner.cancel(fixture.sessionId)).toBe(true)
    await running

    const records = fixture.store.records(fixture.sessionId)
    const end = eventOf(records[records.length - 1])
    expect(end?.data).toMatchObject({ reason: { kind: 'stopped' } })
    // The question batch was withdrawn empty, not left hanging.
    expect(fixture.broker.listQuestions()).toHaveLength(0)
  })

  it('refuses a second concurrent turn for the same session', async () => {
    const fixture = await makeFixture(scriptedEngine([{ text: 'slow answer' }]))
    const first = fixture.runner.run({
      sessionId: fixture.sessionId,
      text: 'first',
      requestId: 'r8',
      signal: { aborted: false, onAbort: () => {} },
    })
    await expect(
      fixture.runner.run({
        sessionId: fixture.sessionId,
        text: 'second',
        requestId: 'r9',
        signal: { aborted: false, onAbort: () => {} },
      }),
    ).rejects.toThrow(/already has a running turn/)
    await first
  })
})
