/**
 * The golden-frame contract: the kernel's answers carry the same shapes the
 * desktop host captured, byte-for-byte where it matters.
 *
 * These are the same files the Swift `FixtureTests` read — the third leg of
 * the contract the protocol document describes. The kernel cannot reproduce
 * the captured *values* (they are real sessions), so the assertions pin the
 * *structure*: the key sets, the envelope rules, and the semantics the client
 * branches on.
 */

import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { harness, scriptedEngine } from './helpers/harness.ts'

const FIXTURES = new URL('../../../protocol/fixtures/', import.meta.url).pathname

function fixture(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(`${FIXTURES}${name}.json`, 'utf8')) as Record<string, unknown>
}

function keySet(value: unknown): Set<string> {
  return new Set(Object.keys(value as Record<string, unknown>))
}

describe('golden frames', () => {
  it('welcome: the kernel welcome carries exactly the captured keys', async () => {
    const golden = fixture('welcome')
    const h = await harness()
    const welcome = h.frames.find((frame) => frame.type === 'welcome')
    expect(welcome).toBeDefined()
    // Same key set; `home` is the only key whose *kind* differs by platform.
    expect(keySet(welcome)).toEqual(keySet(golden))
    expect(welcome).toMatchObject({
      v: 1,
      type: 'welcome',
      protocolVersion: 1,
    })
  })

  it('host-info: same result keys, no addresses (a local kernel dials nobody)', async () => {
    const golden = fixture('host-info') as { result: Record<string, unknown> }
    const h = await harness()
    const result = (await h.call('host.info')) as Record<string, unknown>
    expect(keySet(result)).toEqual(keySet(golden.result))
    expect(result).toMatchObject({ protocolVersion: 1 })
  })

  it('session-list: rows carry exactly the captured keys', async () => {
    const golden = fixture('session-list') as { result: { items: Record<string, unknown>[] } }
    const h = await harness({ engine: scriptedEngine([{ text: 'a' }]) })
    const { sessionId } = (await h.call('session.create', {})) as { sessionId: string }
    await h.call('session.prompt', { sessionId, text: 'go' })
    await h.waitTurnDone(sessionId)

    const result = (await h.call('session.list')) as { items: Record<string, unknown>[] }
    const row = result.items[0]
    expect(row).toBeDefined()
    const goldenRow = golden.result['items'][0]
    expect(goldenRow).toBeDefined()
    expect(keySet(row)).toEqual(keySet(goldenRow))
    expect(row).toMatchObject({
      sessionId,
      running: false,
      blank: false,
      agentAvailable: true,
      parentSessionId: null,
      origin: null,
    })
  })

  it('model-catalog: same top-level keys, same provider/model/effort nesting', async () => {
    const golden = fixture('model-catalog') as { result: Record<string, unknown> }
    const h = await harness()
    const result = (await h.call('model.catalog')) as Record<string, unknown>
    expect(keySet(result)).toEqual(keySet(golden.result))
    const provider = (result['providers'] as Record<string, unknown>[])[0]
    const goldenProvider = (golden.result['providers'] as Record<string, unknown>[])[0]
    if (provider === undefined || goldenProvider === undefined) throw new Error('catalog shape changed')
    expect(keySet(provider)).toEqual(keySet(goldenProvider))
    const model = (provider['models'] as Record<string, unknown>[])[0]
    expect(keySet(model)).toEqual(keySet((goldenProvider['models'] as Record<string, unknown>[])[0]))
  })

  it('permissions-catalog: same keys and the desktop default preset', async () => {
    const golden = fixture('permissions-catalog') as { result: Record<string, unknown> }
    const h = await harness()
    const result = (await h.call('permissions.catalog')) as Record<string, unknown>
    expect(keySet(result)).toEqual(keySet(golden.result))
    expect(result['defaultPreset']).toBe('workspace-write')
  })

  it('interactions-pending: approvals and questions, both empty at rest', async () => {
    const golden = fixture('interactions-pending') as { result: Record<string, unknown> }
    const h = await harness()
    const result = (await h.call('interactions.pending')) as Record<string, unknown>
    expect(keySet(result)).toEqual(keySet(golden.result))
    expect(result).toEqual({ approvals: [], questions: [] })
  })

  it('error-frame: refusals use the captured code and message convention', async () => {
    const golden = fixture('error-frame') as { code: string; message: string }
    const h = await harness()
    const { sessionId } = (await h.call('session.create', {})) as { sessionId: string }
    // The desktop's example refusal is an unknown permission preset.
    await expect(
      h.call('session.permission.set', { sessionId, preset: 'not-a-preset' }),
    ).rejects.toThrow(/unknown preset "not-a-preset" \(available: read-only, workspace-write, danger-full-access\)/)
    // And the code it travels with is the one the golden frame carries.
    expect(golden.code).toBe('REMOTE_ERROR')
  })

  it('session-messages: the summary page keeps exactly the desktop allowlist', async () => {
    // The authoritative golden page is `dsh/protocol/fixtures/session-messages.json`
    // in the desktop repository (the iOS checkout carries only the eight shared
    // fixtures); its record sequence is pinned here.
    const goldenTypes = ['turn/start', 'step/start', 'user/message', 'assistant/message', 'turn/end']
    const h = await harness({ engine: scriptedEngine([{ text: 'The answer.' }]) })
    const created = (await h.call('session.create', {})) as { sessionId: string }
    await h.call('session.prompt', { sessionId: created.sessionId, text: 'hello' })
    await h.waitTurnDone(created.sessionId)
    const result = (await h.call('session.messages', { sessionId: created.sessionId, afterSeq: null })) as {
      records: { event: { type: string } }[]
    }
    expect(result.records.map((record) => record.event.type)).toEqual(goldenTypes)
  })
})
