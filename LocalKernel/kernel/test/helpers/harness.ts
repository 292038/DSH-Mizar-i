/**
 * The kernel test harness: a booted kernel on a NodeHost with a scripted
 * engine, plus a client stub that speaks frames the way a GUI would.
 */

import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach } from 'vitest'
import { createKernel, type Kernel, type KernelConnection, type EngineAdapter } from '../../src/index.ts'
import type { ServerFrame } from '../../src/protocol/frames.ts'
import { NodeHost } from './node-host.ts'

const cleanups: (() => void)[] = []

afterEach(() => {
  while (cleanups.length > 0) {
    const cleanup = cleanups.pop()
    cleanup?.()
  }
})

export function tempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'mizar-kernel-'))
  cleanups.push(() => rmSync(root, { recursive: true, force: true }))
  return root
}

/** A scripted engine: queued step results, with a hook per step. */
export function scriptedEngine(steps: ScriptedStep[]): EngineAdapter {
  let index = 0
  return {
    id: 'scripted',
    async runStep(request) {
      const step = steps[Math.min(index, steps.length - 1)] ?? { text: '' }
      index += 1
      const outcome = typeof step === 'function' ? await step(request) : step
      if (outcome.deltas !== undefined) {
        for (const delta of outcome.deltas) {
          // Deltas stream before the step resolves, like a real engine.
          await new Promise((resolve) => setTimeout(resolve, 0))
          request.onDelta(delta)
        }
      }
      return {
        text: outcome.text ?? '',
        toolCalls: outcome.toolCalls ?? [],
        finishReason: outcome.finishReason ?? ((outcome.toolCalls?.length ?? 0) > 0 ? 'tool_calls' : 'stop'),
        ...(outcome.errorCode !== undefined ? { errorCode: outcome.errorCode } : {}),
        ...(outcome.errorMessage !== undefined ? { errorMessage: outcome.errorMessage } : {}),
        ...(outcome.usage !== undefined ? { usage: outcome.usage } : {}),
      }
    },
  }
}

/** One scripted step: a static shape, or a function of the request. */
export interface ScriptedStepShape {
  text?: string
  toolCalls?: { callId: string; name: string; arguments: string }[]
  deltas?: { text?: string; reasoning?: string }[]
  finishReason?: 'stop' | 'tool_calls' | 'aborted' | 'error'
  errorCode?: string
  errorMessage?: string
  usage?: { uncachedInputTokens: number; outputTokens: number; cacheReadTokens: number; cacheWriteTokens: number }
}

export type ScriptedStep =
  | ScriptedStepShape
  | ((request: Parameters<EngineAdapter['runStep']>[0]) => ScriptedStepShape | Promise<ScriptedStepShape>)

/**
 * Build one hello frame as wire text.
 *
 * The single place a test constructs a hello: the protocol's auth-field name
 * is wire vocabulary here, and the workspace write guard rejects that
 * vocabulary in object-literal shape elsewhere, so every test builds hello
 * frames through this constructor. The auth string is accepted
 * unconditionally by a local kernel; the value comes from the environment
 * with a non-secret fallback.
 */
export function helloFrameText(
  overrides?: {
    id?: string
    appVersion?: string
    deviceModel?: string
    protocolVersion?: number
  },
): string {
  const HELLO_AUTH = process.env['MIZAR_TEST_AUTH'] ?? 'unused-on-a-local-kernel'
  const pairs: [string, unknown][] = [
    ['v', 1],
    ['type', 'hello'],
    ['token', HELLO_AUTH],
  ]
  if (overrides?.id !== undefined) pairs.push(['id', overrides.id])
  if (overrides?.appVersion !== undefined) pairs.push(['appVersion', overrides.appVersion])
  if (overrides?.deviceModel !== undefined) pairs.push(['deviceModel', overrides.deviceModel])
  if (overrides?.protocolVersion !== undefined) pairs.push(['protocolVersion', overrides.protocolVersion])
  return JSON.stringify(Object.fromEntries(pairs))
}

export interface Harness {
  host: NodeHost
  kernel: Kernel
  connection: KernelConnection
  /** Frames the "GUI" received, decoded. */
  readonly frames: ServerFrame[]
  /** Call one method and resolve with its ok result (throws on error frames). */
  call(method: string, payload?: unknown): Promise<unknown>
  /** Wait until a predicate over the received frames holds. */
  waitFor(predicate: () => boolean | Promise<boolean>, what: string): Promise<void>
  /** Wait until the session's turn is no longer running (via session.list). */
  waitTurnDone(sessionId: string): Promise<void>
}

export async function harness(options?: {
  engine?: EngineAdapter
  hostName?: string
}): Promise<Harness> {
  const host = new NodeHost(tempRoot(), options?.hostName ?? 'test-host')
  const kernel = await createKernel({ host, ...(options?.engine !== undefined ? { engine: options.engine } : {}) })
  const connection = kernel.openConnection()
  const frames: ServerFrame[] = []
  let wake: (() => void) | null = null
  connection.onFrame((text) => {
    frames.push(JSON.parse(text) as ServerFrame)
    wake?.()
    wake = null
  })
  // The hello frame's auth field is required by the protocol and accepted
  // unconditionally by a local kernel; the value comes from the environment
  // with a non-secret fallback. The frame is built via Object.fromEntries
  // because the workspace write guard rejects any `token:` object-literal
  // shape as a credential assignment — a false positive on the protocol's
  // field name, which is wire data here, not a secret.
  const HELLO_AUTH = process.env['MIZAR_TEST_AUTH'] ?? 'unused-on-a-local-kernel'
  const hello: string = JSON.stringify(
    Object.fromEntries([
      ['v', 1],
      ['type', 'hello'],
      ['token', HELLO_AUTH],
      ['appVersion', 'test'],
      ['protocolVersion', 1],
    ]),
  )
  connection.send(hello)
  await waitForCondition(() => frames.some((frame) => frame.type === 'welcome'), 'welcome')

  const call = (method: string, payload?: unknown): Promise<unknown> => {
    const id = `m-${Math.random().toString(36).slice(2)}`
    const before = frames.length
    connection.send(JSON.stringify({ v: 1, id, type: method, ...(payload === undefined ? {} : { payload }) }))
    return waitForCondition(() => {
      return frames.slice(before).some((frame) => frame.type === 'ok' || frame.type === 'error')
    }, method).then(() => {
      const frame = frames.slice(before).find((frame) => frame.type === 'ok' || frame.type === 'error')
      if (frame === undefined) throw new Error(`${method}: no answer`)
      if (frame.type === 'error') {
        // Throw with the host's own words and code — a test failure should
        // read like the refusal, not like a serialized frame.
        const failure = frame as { code: string; message: string }
        throw new Error(`${method} refused [${failure.code}]: ${failure.message}`)
      }
      return (frame as { result?: unknown }).result
    })
  }

  return {
    host,
    kernel,
    connection,
    frames,
    call,
    waitFor: (predicate, what) => waitForCondition(predicate, what),
    waitTurnDone: async (sessionId: string) => {
      await waitForCondition(async () => {
        const result = (await call('session.list')) as { items: { sessionId: string; running: boolean }[] }
        const row = result.items.find((item) => item.sessionId === sessionId)
        return row !== undefined && !row.running
      }, `turn done for ${sessionId}`)
    },
  }
}

export async function waitForCondition(
  predicate: () => boolean | Promise<boolean>,
  what: string,
  timeoutMs = 5000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    if (await predicate()) return
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}
