/**
 * The turn runner — the kernel's agent loop.
 *
 * One prompt is one turn. The runner owns the whole lifecycle and writes every
 * record, so the log always tells one true story:
 *
 *     turn/start {turn}
 *     step/start {turn, step: 1}
 *     user/message {content, source, role, id}
 *     assistant/attempt {turn, step, attempt, stream}   ← the streamed deltas
 *     assistant/message {turn, step, message}            ← the step's final text
 *     tool/call {turn, step, callId, name, arguments}
 *     tool/result {turn, step, callId, name, output|error}
 *     step/start {turn, step: 2}                        ← when tools ran
 *     …
 *     turn/end {turn, reason}
 *
 * The step marker opens before the prompt lands, matching the desktop's log
 * order. Tool execution is gated by the permission preset (an approval card
 * for anything the preset does not cover); a refused call still logs its
 * `tool/call` and answers with a denial result, because the engine needs to
 * see the refusal to change course.
 *
 * Cancellation is cooperative and prompt: the engine stream aborts, pending
 * approvals settle `cancelled`, and the turn ends with reason kind `stopped`.
 * A crash mid-turn leaves the log without `turn/end`; the store closes such a
 * turn as `stopped` at the next boot.
 */

import type { PlatformHost } from '../host/host.ts'
import type { EngineAdapter, EngineMessage, EngineToolCall, TurnSignal } from '../engine/types.ts'
import type { InteractionsBroker } from './interactions.ts'
import type { SessionStore } from './session-store.ts'
import type { KernelConfig } from './config.ts'
import { eventOf } from './records.ts'
import { builtinTools, gatedRun, type ToolContext } from './tools.ts'

/** The runner's view of one turn's inputs. */
export interface TurnRequest {
  readonly sessionId: string
  readonly text: string
  /** The idempotency key the prompt arrived with; echoed on the user message. */
  readonly requestId: string
  readonly clientTimeZone?: string
  readonly signal: TurnSignal
}

/** Whether the runner accepted a turn for this session. */
export interface TurnStart {
  readonly turn: number
}

const MAX_STEPS = 32

/** One in-flight turn: its number, its signal, and how to abort it. */
interface RunningTurn {
  readonly turn: number
  readonly signal: TurnSignal
  readonly cancel: () => void
}

export class TurnRunner {
  readonly #host: PlatformHost
  readonly #store: SessionStore
  readonly #engine: EngineAdapter
  readonly #broker: InteractionsBroker
  readonly #config: () => KernelConfig
  readonly #running = new Map<string, RunningTurn>()

  constructor(input: {
    host: PlatformHost
    store: SessionStore
    engine: EngineAdapter
    broker: InteractionsBroker
    config: () => KernelConfig
  }) {
    this.#host = input.host
    this.#store = input.store
    this.#engine = input.engine
    this.#broker = input.broker
    this.#config = input.config
  }

  /** Whether a turn is running for the session. */
  isRunning(sessionId: string): boolean {
    return this.#running.has(sessionId)
  }

  /**
   * Cancel the session's running turn.
   *
   * Returns whether a turn was running. The turn ends with reason kind
   * `stopped` — cancellation is an operator action, not an error.
   */
  cancel(sessionId: string): boolean {
    const running = this.#running.get(sessionId)
    if (running === undefined) return false
    running.cancel()
    return true
  }

  /** Run one turn. Resolves when the turn's `turn/end` is in the log. */
  async run(request: TurnRequest): Promise<TurnStart> {
    const sessionId = request.sessionId
    if (this.#running.has(sessionId)) {
      throw new Error(`session "${sessionId}" already has a running turn`)
    }
    const meta = this.#store.get(sessionId)
    if (meta === null) throw new Error(`session "${sessionId}" is not open`)

    const turn = this.#store.allocateTurn(sessionId)
    let aborted = false
    const listeners: (() => void)[] = []
    const signal: TurnSignal = {
      get aborted() {
        return aborted
      },
      onAbort(cb: () => void) {
        listeners.push(cb)
      },
    }
    const cancel = () => {
      if (aborted) return
      aborted = true
      for (const listener of listeners) listener()
    }

    const running: RunningTurn = { turn, signal, cancel }
    this.#running.set(sessionId, running)
    await this.#store.beginTurn(sessionId, turn)

    try {
      await this.#store.append(sessionId, 'turn/start', { turn })
      await this.#store.append(sessionId, 'step/start', { turn, step: 1 })
      await this.#store.append(sessionId, 'user/message', {
        content: [{ type: 'text', text: request.text }],
        source: { kind: 'user', rpcId: request.requestId },
        role: 'user',
        id: this.#host.uuid(),
      })

      let step = 1
      while (true) {
        // The abort check comes before the engine call: a cancelled turn
        // must not spend another engine round-trip, however the engine
        // handles its own signal.
        if (signal.aborted) {
          await this.#appendEnd(sessionId, turn, { kind: 'stopped' })
          return { turn }
        }
        const outcome = await this.#engineStep(sessionId, turn, step, signal)

        if (signal.aborted) {
          await this.#appendEnd(sessionId, turn, { kind: 'stopped' })
          return { turn }
        }
        if (outcome.finishReason === 'error') {
          await this.#appendEnd(sessionId, turn, {
            kind: 'error',
            error: {
              code: outcome.errorCode ?? 'REMOTE_ERROR',
              message: outcome.errorMessage ?? 'the engine failed',
            },
          })
          return { turn }
        }

        if (outcome.toolCalls.length === 0) {
          await this.#appendEnd(sessionId, turn, { kind: 'completed' })
          return { turn }
        }

        if (step >= MAX_STEPS) {
          await this.#appendEnd(sessionId, turn, {
            kind: 'error',
            error: { code: 'STEP_LIMIT', message: `the turn exceeded ${MAX_STEPS} steps` },
          })
          return { turn }
        }

        step += 1
        await this.#store.append(sessionId, 'step/start', { turn, step })
      }
    } catch (error) {
      // An unexpected runner failure is an error turn, never a hung one.
      await this.#appendEnd(sessionId, turn, {
        kind: 'error',
        error: {
          code: 'INTERNAL',
          message: error instanceof Error ? error.message : String(error),
        },
      })
      return { turn }
    } finally {
      this.#running.delete(sessionId)
      await this.#store.endTurn(sessionId, turn)
    }
  }

  /**
   * One engine call with its records.
   *
   * Deltas accumulate into the step's `assistant/attempt` record — the
   * durable compact runs the desktop's activity reader flattens into
   * `thinking` rows. The step's final text becomes the `assistant/message`.
   */
  async #engineStep(
    sessionId: string,
    turn: number,
    step: number,
    signal: TurnSignal,
  ): Promise<StepOutcome> {
    const startedAt = this.#host.now()
    const messages = this.#assembleMessages(sessionId)
    const config = this.#config()
    const meta = this.#store.get(sessionId)
    const model = meta?.selectedModel ?? config.defaultModel

    const textChunks: string[] = []
    const reasoningChunks: string[] = []

    const result = await this.#engine.runStep({
      messages,
      tools: builtinTools().map((tool) => tool.spec),
      model: {
        provider: model.provider,
        model: model.model,
        ...(model.reasoningEffort !== undefined ? { reasoningEffort: model.reasoningEffort } : {}),
      },
      onDelta: (delta) => {
        if (delta.text !== undefined) textChunks.push(delta.text)
        if (delta.reasoning !== undefined) reasoningChunks.push(delta.reasoning)
      },
      signal,
    })

    const llmMs = this.#host.now() - startedAt
    await this.#accumulateTiming(sessionId, llmMs, false)
    if (result.usage !== undefined) {
      await this.#accumulateUsage(sessionId, result.usage)
    }

    const stream: Record<string, unknown>[] = []
    if (textChunks.length > 0) stream.push({ type: 'text-chunks', texts: textChunks })
    if (reasoningChunks.length > 0) stream.push({ type: 'reasoning-chunks', texts: reasoningChunks })
    if (stream.length > 0) {
      await this.#store.append(sessionId, 'assistant/attempt', { turn, step, attempt: 1, stream })
    }

    if (result.text !== '') {
      await this.#store.append(sessionId, 'assistant/message', {
        turn,
        step,
        message: { role: 'assistant', content: [{ type: 'text', text: result.text }] },
      })
    }

    if (result.finishReason === 'error') {
      return {
        finishReason: 'error',
        toolCalls: [],
        ...(result.errorCode !== undefined ? { errorCode: result.errorCode } : {}),
        ...(result.errorMessage !== undefined ? { errorMessage: result.errorMessage } : {}),
      }
    }
    if (result.finishReason === 'aborted') {
      return { finishReason: 'aborted', toolCalls: [] }
    }

    for (const call of result.toolCalls) {
      if (signal.aborted) break
      await this.#runTool(sessionId, turn, step, call, signal)
    }

    return { finishReason: result.finishReason, toolCalls: result.toolCalls }
  }

  /**
   * Execute one tool call with its records.
   *
   * Unparsable arguments are a tool failure, not a turn failure: the engine
   * gets the error as the result and can retry with better arguments.
   */
  async #runTool(
    sessionId: string,
    turn: number,
    step: number,
    call: EngineToolCall,
    signal: TurnSignal,
  ): Promise<void> {
    await this.#store.append(sessionId, 'tool/call', {
      turn,
      step,
      callId: call.callId,
      name: call.name,
      arguments: call.arguments,
    })

    let args: Record<string, unknown>
    try {
      const parsed: unknown = JSON.parse(call.arguments === '' ? '{}' : call.arguments)
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        throw new Error('arguments must be a JSON object')
      }
      args = parsed as Record<string, unknown>
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      await this.#store.append(sessionId, 'tool/result', {
        turn,
        step,
        callId: call.callId,
        name: call.name,
        error: { code: 'INVALID_ARGUMENTS', message },
      })
      return
    }

    const definition = builtinTools().find((tool) => tool.spec.name === call.name)
    if (definition === undefined) {
      const message = `unknown tool "${call.name}"`
      await this.#store.append(sessionId, 'tool/result', {
        turn,
        step,
        callId: call.callId,
        name: call.name,
        error: { code: 'UNKNOWN_TOOL', message },
      })
      return
    }

    const startedAt = this.#host.now()
    const result = await gatedRun(definition, args, this.#toolContext(sessionId, call.callId, signal))
    await this.#accumulateTiming(sessionId, this.#host.now() - startedAt, true)

    if ('failure' in result) {
      await this.#store.append(sessionId, 'tool/result', {
        turn,
        step,
        callId: call.callId,
        name: call.name,
        error: { code: result.failure.code, message: result.failure.message },
      })
      return
    }

    await this.#store.append(sessionId, 'tool/result', {
      turn,
      step,
      callId: call.callId,
      name: call.name,
      output: result.output,
    })
  }

  /**
   * Assemble the engine's message list from the log.
   *
   * System prompt, then every turn's user message, assistant messages and
   * tool results in log order. Tool calls fold back into the assistant
   * message that produced them — the shape the engine API expects — and a
   * step that called tools without producing text gets a synthetic carrier
   * message. Narration (`assistant/attempt`) does not go back to the engine:
   * it is already folded into the assistant messages.
   */
  #assembleMessages(sessionId: string): EngineMessage[] {
    const config = this.#config()
    const meta = this.#store.get(sessionId)
    const workspace = meta?.cwd ?? ''

    const system: string[] = [
      'You are the DSH local agent, running on the operator\'s phone or tablet.',
      'You work inside a sandboxed workspace directory. File tools take paths relative to it.',
      'You cannot run shell commands; use the file tools and ask the operator for anything else.',
      'Be direct and concise: the operator reads you on a small screen.',
    ]
    if (workspace !== '') system.push(`The session's workspace is ${workspace}.`)
    if (config.systemPromptAddendum !== '') system.push(config.systemPromptAddendum)

    const messages: EngineMessage[] = [{ role: 'system', content: system.join(' ') }]

    /** The assistant message tool calls are still folding into. */
    let pending: EngineMessage | null = null
    const flushPending = () => {
      if (pending !== null) {
        messages.push(pending)
        pending = null
      }
    }

    for (const record of this.#store.records(sessionId)) {
      const event = eventOf(record)
      if (event === null) continue
      const data = event['data']
      if (typeof data !== 'object' || data === null) continue
      const fields = data as Record<string, unknown>
      switch (event['type']) {
        case 'user/message': {
          flushPending()
          const text = textOfContent(fields['content'])
          if (text !== '') messages.push({ role: 'user', content: text })
          break
        }
        case 'assistant/message': {
          flushPending()
          const message = fields['message']
          const content = typeof message === 'object' && message !== null
            ? (message as Record<string, unknown>)['content']
            : undefined
          const text = textOfContent(content)
          pending = { role: 'assistant', content: text, toolCalls: [] }
          break
        }
        case 'tool/call': {
          if (pending === null) {
            // A step that called tools without producing text first.
            pending = { role: 'assistant', content: '', toolCalls: [] }
          }
          if (typeof fields['callId'] === 'string' && typeof fields['name'] === 'string') {
            pending.toolCalls?.push({
              callId: fields['callId'],
              name: fields['name'],
              arguments: typeof fields['arguments'] === 'string' ? fields['arguments'] : '{}',
            })
          }
          break
        }
        case 'tool/result': {
          flushPending()
          const callId = fields['callId']
          const output = typeof fields['output'] === 'string' ? fields['output'] : undefined
          const content =
            output ??
            (() => {
              const failure = fields['error']
              if (typeof failure !== 'object' || failure === null) return undefined
              const fields2 = failure as Record<string, unknown>
              const code = typeof fields2['code'] === 'string' ? fields2['code'] : 'FAILED'
              const message = typeof fields2['message'] === 'string' ? fields2['message'] : ''
              return `error (${code}): ${message}`
            })()
          if (typeof callId === 'string' && content !== undefined) {
            messages.push({ role: 'tool', content, toolCallId: callId })
          }
          break
        }
        default:
          break
      }
    }
    flushPending()

    return messages
  }

  #toolContext(sessionId: string, callId: string, signal: TurnSignal): ToolContext & { callId: string } {
    const config = this.#config()
    const meta = this.#store.get(sessionId)
    return {
      host: this.#host,
      sessionId,
      workspacePath: `workspace/${sessionId}`,
      workspaceDisplay: `${this.#host.home}/workspace/${sessionId}`,
      preset: meta?.permissionPreset ?? config.defaultPreset,
      broker: this.#broker,
      signal,
      config,
      callId,
    }
  }

  async #appendEnd(sessionId: string, turn: number, reason: Record<string, unknown>): Promise<void> {
    await this.#store.append(sessionId, 'turn/end', { turn, reason })
  }

  async #accumulateTiming(sessionId: string, ms: number, tool: boolean): Promise<void> {
    const meta = this.#store.get(sessionId)
    if (meta === null) return
    if (tool) meta.toolMs += ms
    else meta.llmMs += ms
    await this.#store.flushMeta(sessionId)
  }

  async #accumulateUsage(
    sessionId: string,
    usage: { uncachedInputTokens: number; outputTokens: number; cacheReadTokens: number; cacheWriteTokens: number },
  ): Promise<void> {
    const meta = this.#store.get(sessionId)
    if (meta === null) return
    const current = meta.usage ?? {
      uncachedInputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    }
    meta.usage = {
      uncachedInputTokens: current.uncachedInputTokens + usage.uncachedInputTokens,
      outputTokens: current.outputTokens + usage.outputTokens,
      cacheReadTokens: current.cacheReadTokens + usage.cacheReadTokens,
      cacheWriteTokens: current.cacheWriteTokens + usage.cacheWriteTokens,
    }
    await this.#store.flushMeta(sessionId)
  }
}

interface StepOutcome {
  finishReason: 'stop' | 'tool_calls' | 'aborted' | 'error'
  toolCalls: readonly EngineToolCall[]
  errorCode?: string
  errorMessage?: string
}

/** The readable text of a content-part array, or `''`. */
function textOfContent(content: unknown): string {
  if (!Array.isArray(content)) return ''
  const parts: string[] = []
  for (const part of content) {
    if (typeof part !== 'object' || part === null) continue
    const text = (part as Record<string, unknown>)['text']
    if (typeof text === 'string') parts.push(text)
  }
  return parts.join('')
}
